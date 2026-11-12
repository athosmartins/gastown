#!/usr/bin/env bash
# hetzner-ssh-lockdown.selftest.sh — hermético: useradd, ufw, fail2ban-client, sshd, systemctl, journalctl, sudo, visudo… são stubs; nada toca em usuário, firewall ou sshd de verdade (ga-qg1dw5z.2).
# Usa o ssh-keygen REAL (fingerprint de chave de verdade) e o zgrep real.
#
# ## Contents
#   Casos · Controles negativos · Uso · O que este teste NÃO prova
#
# CASOS: uso · status/origins (só leem; falha de leitura é `?`/3, nunca "inativo"/"vazio") · admin (cria com sudo, senha travada, SÓ a chave pública ed25519/ecdsa; recusa nome reservado, chave privada, RSA, opções, 2 chaves,
#   não-root; chave diferente exige --replace; falha em cada passo → 98 sem state; --replace que falha invalida o state) · fail2ban (ignoreip do mini obrigatório e conferido de volta; falha → desfaz e para) · ufw (regra da 22 ANTES de tudo, rede de segurança
#   armada ANTES do enable, sem rede não liga) · rootcut (as 5 provas, a chave do authorized_keys = a gravada, o login real do admin lido do journal desde a instalação, rede de segurança de 10 min, efetivo conferido; falha → drop-in removido) · confirm · undo · não-root.
# CONTROLES NEGATIVOS: os mutantes H1-H41 têm de ser REPROVADOS pelo caso correspondente (o caso falha no mutante).
# USO: hetzner-ssh-lockdown.selftest.sh [--sem-mutantes]   (a prod-test usa --sem-mutantes; a bateria completa roda no gate)
# O QUE NÃO PROVA: que o sshd/ufw/fail2ban de verdade se comportam como os stubs. Isso só a execução no nó prova — por isso cada passo vivo tem rede de segurança de 10 min e prova por conexão NOVA (docs/runbooks/hetzner-ssh-lockdown.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG="$HERE/hetzner-ssh-lockdown.sh"
MUTANTES=1; [ "${1:-}" = "--sem-mutantes" ] && MUTANTES=0
T=$(mktemp -d "${TMPDIR:-/tmp}/hzn-lockdown-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
W="$T/w"; LOG="$T/log"; OUT="$T/out"; ERR="$T/err"; GT_ETC="$W/etc"
mkdir -p "$T/stubs" "$T/real" "$W"
export T W LOG GT_ETC
unset FAKE_UID FAKE_HOME ABSENT FAIL_STEP GETENT_FAIL UFW_STATUS UFW_DROP_RULE UFW_NOSTICK NO_ARM F2B_NOJAIL F2B_IGNORE SSHD_T SSHD_IGNORE_DROPIN SUDO_MODE ZGREP_FAIL APT_NOBIN
mk() { cat > "$T/real/$1"; chmod +x "$T/real/$1"; }
mk id <<'EOF'
#!/bin/bash
[ "$*" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
mk getent <<'EOF'
#!/bin/bash
echo "getent $*" >> "$LOG"
[ "$1" = passwd ] || exit 2
case "${GETENT_FAIL:-}" in all|"$2") exit 3 ;; esac
l=$(awk -F: -v u="$2" '$1==u' "$W/passwd.db")
[ -n "$l" ] || exit 2
echo "$l"
EOF
mk useradd <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$LOG"
[ "${FAIL_STEP:-}" = useradd ] && exit 1
for a; do n=$a; done
home=${FAKE_HOME:-$W/home/$n}; [ -n "${FAKE_HOME:-}" ] || mkdir -p "$home"
echo "$n:x:1100:1100::$home:/bin/bash" >> "$W/passwd.db"
EOF
mk usermod <<'EOF'
#!/bin/bash
echo "usermod $*" >> "$LOG"
[ "${FAIL_STEP:-}" = usermod ] && exit 1
exit 0
EOF
mk passwd <<'EOF'
#!/bin/bash
echo "passwd $*" >> "$LOG"
[ "${FAIL_STEP:-}" = passwd ] && exit 1
exit 0
EOF
mk chown <<'EOF'
#!/bin/bash
echo "chown $*" >> "$LOG"
[ "${FAIL_STEP:-}" = chown ] && exit 1
exit 0
EOF
mk visudo <<'EOF'
#!/bin/bash
echo "visudo $*" >> "$LOG"
[ "${FAIL_STEP:-}" = visudo ] && exit 1
exit 0
EOF
mk logger <<'EOF'
#!/bin/bash
echo "logger $*" >> "$LOG"
EOF
mk sleep <<'EOF'
#!/bin/bash
exit 0
EOF
mk apt-get <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$LOG"
[ "${FAIL_STEP:-}" = apt ] && exit 1
[ "${APT_NOBIN:-}" = 1 ] || ln -sf "$T/real/fail2ban-client" "$T/stubs/fail2ban-client"
exit 0
EOF
mk systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "stop gt-ufw-revert.timer"|"stop gt-rootcut-revert.timer") [ "${FAIL_STEP:-}" = timer-stuck ] || rm -f "$W/timer.${2%.timer}" ;;
  "is-active gt-ufw-revert.timer"|"is-active gt-rootcut-revert.timer") [ -e "$W/timer.${2%.timer}" ]; exit $? ;;
  "enable fail2ban") [ "${FAIL_STEP:-}" = f2b-enable ] && exit 1 ;;
  "restart fail2ban") [ "${FAIL_STEP:-}" = f2b-restart ] && exit 1; [ "${F2B_NOJAIL:-}" = 1 ] || : > "$W/f2b.up" ;;
  "stop fail2ban") rm -f "$W/f2b.up" ;;
  "reload ssh") [ "${FAIL_STEP:-}" = reload ] && exit 1 ;;
esac
exit 0
EOF
mk systemd-run <<'EOF'
#!/bin/bash
echo "systemd-run $*" >> "$LOG"
[ "${FAIL_STEP:-}" = systemd-run ] && exit 1
for a; do case "$a" in --unit=*) u=${a#--unit=} ;; esac; done
[ "${NO_ARM:-}" = 1 ] || : > "$W/timer.$u"
exit 0
EOF
mk ufw <<'EOF'
#!/bin/bash
echo "ufw $*" >> "$LOG"
case "$1" in
  status) case "${UFW_STATUS:-}" in garbage) echo boom ;; fail) exit 1 ;; *) if [ -e "$W/ufw.on" ]; then echo "Status: active"; else echo "Status: inactive"; fi ;; esac ;;
  default) [ "${FAIL_STEP:-}" = default ] && exit 1 ;;
  allow) [ "${FAIL_STEP:-}" = allow ] && exit 1; [ "${UFW_DROP_RULE:-}" = 1 ] || echo "ufw $*" >> "$W/ufw.added" ;;
  show) echo "Added user rules (see 'ufw status' for running firewall):"; cat "$W/ufw.added" 2>/dev/null ;;
  --force) [ "${FAIL_STEP:-}" = enable ] && exit 1; [ "${UFW_NOSTICK:-}" = 1 ] || : > "$W/ufw.on" ;;
  disable) rm -f "$W/ufw.on" ;;
esac
exit 0
EOF
mk fail2ban-client <<'EOF'
#!/bin/bash
echo "fail2ban-client $*" >> "$LOG"
case "$*" in
  "-t") [ "${FAIL_STEP:-}" = f2b-test ] && exit 1 ;;
  "status sshd") [ -e "$W/f2b.up" ] || exit 1 ;;
  "get sshd ignoreip") case "${F2B_IGNORE:-}" in fail) exit 1 ;; empty) ;; other) echo "|- IP list: 127.0.0.1/8 ::1" ;; substr) echo "|- IP list: 127.0.0.1/8 ::1 198.51.100.77" ;; *) awk -F= '$1 ~ /^ignoreip/ {print "|- IP list:" $2}' "$GT_ETC/fail2ban/jail.d/gt-sshd.local" ;; esac ;;
esac
exit 0
EOF
mk sshd <<'EOF'
#!/bin/bash
echo "sshd $*" >> "$LOG"
case "$1" in
  -t) [ "${FAIL_STEP:-}" = sshd-t ] && exit 1 ;;
  -T) [ "${SSHD_T:-}" = fail ] && exit 1; [ "${SSHD_T:-}" = empty ] && exit 0
      if [ -e "$GT_ETC/ssh/sshd_config.d/10-gt-lockdown.conf" ] && [ "${SSHD_IGNORE_DROPIN:-}" != 1 ]; then echo "permitrootlogin no"; else echo "permitrootlogin prohibit-password"; fi ;;
esac
exit 0
EOF
mk journalctl <<'EOF'
#!/bin/bash
echo "journalctl $*" >> "$LOG"
[ "${FAIL_STEP:-}" = journal ] && exit 1
cat "$W/journal" 2>/dev/null
exit 0
EOF
mk sudo <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$LOG"
case "${SUDO_MODE:-ok}" in fail) exit 1 ;; denied) echo "User $4 is not allowed to run sudo on x." ;; *) echo "User $4 may run the following commands on x:"; echo "    (ALL) NOPASSWD: ALL" ;; esac
exit 0
EOF
mk zgrep <<'EOF'
#!/bin/bash
[ "${ZGREP_FAIL:-}" = 1 ] && exit 2
exec /usr/bin/zgrep "$@"
EOF
relink() { local f nm; for f in "$T"/real/*; do nm=${f##*/}; case " ${ABSENT:-} " in *" $nm "*) rm -f "$T/stubs/$nm" ;; *) ln -sf "$f" "$T/stubs/$nm" ;; esac; done; }

# o script de root reseta o PATH e aponta para /etc, /var/log e /var/lib: a cópia testada troca SÓ essas 5 linhas (conferido abaixo contra o original)
for l in 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' 'ETC=/etc' 'LOGDIR=/var/log' 'STATE=/var/lib/gt-lockdown' 'WAIT_TRIES=10'; do
  grep -qx -- "$l" "$ORIG" || { echo "FAIL o original não tem a linha esperada: $l"; exit 1; }
done
sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#^ETC=/etc\$#ETC=$W/etc#" -e "s#^LOGDIR=/var/log\$#LOGDIR=$W/log#" \
    -e "s#^STATE=/var/lib/gt-lockdown\$#STATE=$W/state#" -e "s#^WAIT_TRIES=10\$#WAIT_TRIES=2#" "$ORIG" > "$T/H.sh"; chmod +x "$T/H.sh"

# chaves de verdade (ssh-keygen real): K1 = a do Athos, K2 = outra, ECK = ecdsa, RSAK = rsa (recusada)
kg() { ssh-keygen -q -t "$1" ${3:-} -N '' -C "teste-$2" -f "$T/$2" >/dev/null 2>&1 || { echo "FAIL ssh-keygen não gerou $2"; exit 1; }; }
kg ed25519 K1; kg ed25519 K2; kg ecdsa ECK; kg rsa RSAK "-b 1024"
FP1=$(ssh-keygen -l -f "$T/K1.pub" | awk '{print $2}'); FP2=$(ssh-keygen -l -f "$T/K2.pub" | awk '{print $2}')
printf 'from="198.51.100.7" %s\n' "$(cat "$T/K1.pub")" > "$T/k-opt.pub"; cat "$T/K1.pub" "$T/K2.pub" > "$T/k-two.pub"; echo '# só comentário' > "$T/k-empty.pub"

n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
ck "a cópia testada difere do original só nas 5 linhas literais" test "$(diff "$ORIG" "$T/H.sh" | grep '^<' | grep -v -c -E '^< (PATH|ETC|LOGDIR|STATE|WAIT_TRIES)=')" = 0
ck "…e são exatamente 5" test "$(diff "$ORIG" "$T/H.sh" | grep -c '^<')" = 5
rcis() { [ "$RC" = "$1" ]; }
has() { grep -q -E -- "$2" "$1"; }
hasnt() { ! grep -q -E -- "$2" "$1"; }
hasx() { grep -q -x -F -- "$2" "$1"; }
exists() { [ -e "$1" ]; }
order() { local prev=0 p pat; for pat in "$@"; do p=$(grep -n -E -- "$pat" "$LOG" | head -n 1 | cut -d: -f1); [ -n "$p" ] && [ "$p" -gt "$prev" ] || return 1; prev=$p; done; }
perm() { ls -ld "$1" | awk '{print substr($1,1,10)}'; }
world() { find "$W" -mindepth 1 -delete 2>/dev/null; mkdir -p "$W/etc/ssh/sshd_config.d" "$W/etc/sudoers.d" "$W/log" "$W/home"; : > "$W/log/auth.log"; : > "$W/journal"; : > "$W/ufw.added"
  printf 'root:x:0:0::%s/home/root:/bin/bash\nrunner:x:1000:1000::%s/home/runner:/bin/bash\ndados:x:1001:1001::%s/home/dados:/bin/bash\n' "$W" "$W" "$W" > "$W/passwd.db"; }
# relink só quando o conjunto de stubs ausentes muda (ou mudou na rodada anterior: o apt-get stub recria o binário)
relink; LAST_ABSENT=""
go() { local s=$1; shift; : > "$LOG"; if [ -n "${ABSENT:-}" ] || [ -n "$LAST_ABSENT" ]; then relink; LAST_ABSENT=${ABSENT:-}; fi; "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
epoch_of() { awk -F= '$1=="epoch"{print $2}' "$W/state/admin"; }
login_line() { printf 'Nov 11 21:00:00 no sshd[1]: Accepted publickey for %s from 203.0.113.9 port 5 ssh2: ED25519 %s\n' "$1" "$2" >> "$W/journal"; }
ufw_on() { : > "$W/ufw.on"; }
f2b_up() { : > "$W/f2b.up"; }
D_ROOT="$W/etc/ssh/sshd_config.d/10-gt-lockdown.conf"; J_F2B="$W/etc/fail2ban/jail.d/gt-sshd.local"; SUDOERS="$W/etc/sudoers.d/90-gt-admin-opadm"; HOME_ADM="$W/home/opadm"
# mundo pronto para o rootcut: admin instalado, ufw ativo, jail de pé, e o login real do admin no journal
prep() { world; go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; ufw_on; f2b_up; login_line opadm "$FP1"; }
MUT_ADMIN='^(useradd|usermod|passwd|visudo|chown)'
MUT_UFW='^(ufw (allow|default|--force|disable)|systemd-run|systemctl (stop|reload))'
MUT_F2B='^(apt-get|systemctl|fail2ban-client)'
MUT_ROOT='^(systemd-run|systemctl reload ssh)'
refused() { local lbl=$1 s=$2 mut=$3; shift 3; go "$s" "$@"; ck "$lbl: rc 2" rcis 2; ck "$lbl: diz recusado" has "$ERR" '^LOCKDOWN-[a-z0-9]+: recusado:'; ck "$lbl: nada mudou" hasnt "$LOG" "$mut"; }
cant() { local lbl=$1 s=$2 mut=$3; shift 3; go "$s" "$@"; ck "$lbl: rc 3" rcis 3; ck "$lbl: diz nao-consegui" has "$ERR" '^LOCKDOWN-[a-z0-9]+: nao-consegui:'; ck "$lbl: nada mudou" hasnt "$LOG" "$mut"; }

case_usage() { world; go "$1"; ck "sem argumento: rc 2" rcis 2; go "$1" xpto; ck "subcomando desconhecido: rc 2" rcis 2; ck "diz o uso" has "$ERR" '^uso: '; }
case_status() { world; go "$1" status; ck "status: rc 0" rcis 0
  ck "status: sshd lido" has "$OUT" '^LOCKDOWN-status: sshd permitrootlogin=prohibit-password$'; ck "status: ufw inativo" has "$OUT" '^LOCKDOWN-status: ufw=inativo$'
  ck "status: fail2ban instalado mas sem jail" has "$OUT" '^LOCKDOWN-status: fail2ban=sem-jail$'; ck "status: sem admin" has "$OUT" '^LOCKDOWN-status: admin=nenhum$'
  ck "status só lê" hasnt "$LOG" '^(useradd|usermod|passwd|apt-get|systemd-run|ufw (allow|default|--force|disable)|systemctl (restart|stop|enable|reload))'
  ABSENT=" fail2ban-client " go "$1" status; ck "fail2ban ausente: diz ausente" has "$OUT" '^LOCKDOWN-status: fail2ban=ausente$'
  ufw_on; f2b_up; go "$1" status; ck "ufw ativo" has "$OUT" '^LOCKDOWN-status: ufw=ativo$'; ck "fail2ban ativo" has "$OUT" '^LOCKDOWN-status: fail2ban=ativo$'
  UFW_STATUS=garbage go "$1" status; ck "ufw ilegível: ? (nunca inativo)" has "$OUT" '^LOCKDOWN-status: ufw=\?$'
  UFW_STATUS=fail go "$1" status; ck "ufw que falha ao ler: ? (nunca inativo)" has "$OUT" '^LOCKDOWN-status: ufw=\?$'
  SSHD_T=empty go "$1" status; ck "sshd sem a chave: ?" has "$OUT" 'permitrootlogin=\?$'; SSHD_T=fail go "$1" status; ck "sshd -T que falha: ?" has "$OUT" 'permitrootlogin=\?$'
  go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; go "$1" status; ck "admin gravado aparece" has "$OUT" '^LOCKDOWN-status: admin=opadm$'; }
case_origins() { world
  printf '%s\n' 'Nov 10 no sshd[1]: Accepted publickey for runner from 198.51.100.7 port 1 ssh2: ED25519 SHA256:aaa' 'Nov 10 no sshd[2]: Accepted publickey for runner from 198.51.100.7 port 2 ssh2: ED25519 SHA256:aaa' \
    'Nov 10 no sshd[3]: Accepted publickey for root from 203.0.113.5 port 3 ssh2: RSA SHA256:bbb' 'Nov 10 no sshd[4]: Failed password for invalid user x from 192.0.2.1 port 4 ssh2' > "$W/log/auth.log"
  go "$1" origins; ck "origins: rc 0" rcis 0; ck "conta o runner (2 por IP)" has "$OUT" '^LOCKDOWN-origins: user=runner ip=198\.51\.100\.7 n=2$'; ck "conta o root" has "$OUT" '^LOCKDOWN-origins: user=root ip=203\.0\.113\.5 n=1$'; ck "ignora tentativa falha" hasnt "$OUT" '192\.0\.2\.1'
  echo 'Nov 10 nada aqui' > "$W/log/auth.log"; go "$1" origins; ck "sem Accepted: rc 0" rcis 0; ck "sem Accepted: diz vazio" has "$OUT" '^LOCKDOWN-origins: vazio'
  ZGREP_FAIL=1 go "$1" origins; ck "zgrep que falha: rc 3" rcis 3; ck "zgrep que falha: NÃO diz vazio" hasnt "$OUT" 'vazio'; ck "zgrep que falha: diz nao-consegui" has "$ERR" '^LOCKDOWN-origins: nao-consegui:'
  rm -f "$W/log/auth.log"; go "$1" origins; ck "sem auth.log: rc 3" rcis 3; ck "sem auth.log: NÃO diz vazio" hasnt "$OUT" 'vazio'; }
case_admin_ok() { world; go "$1" admin --user opadm --pubkey-file "$T/K1.pub"
  ck "admin: rc 0" rcis 0; ck "diz o fingerprint" hasx "$OUT" "LOCKDOWN-admin: ok user=opadm fp=$FP1"; ck "manda provar por 2a sessão nova" has "$OUT" 'PROXIMO: numa 2a sessao NOVA'
  ck "useradd -m com shell" has "$LOG" '^useradd -m -s /bin/bash opadm$'; ck "grupo sudo" has "$LOG" '^usermod -aG sudo opadm$'; ck "senha travada" has "$LOG" '^passwd -l opadm$'
  ck "authorized_keys = só a pública" test "$(cat "$HOME_ADM/.ssh/authorized_keys")" = "$(cat "$T/K1.pub")"; ck "authorized_keys 600" test "$(perm "$HOME_ADM/.ssh/authorized_keys")" = "-rw-------"; ck ".ssh 700" test "$(perm "$HOME_ADM/.ssh")" = "drwx------"
  ck "sudoers: NOPASSWD só do admin" test "$(cat "$SUDOERS")" = "opadm ALL=(ALL) NOPASSWD:ALL"; ck "sudoers 440" test "$(perm "$SUDOERS")" = "-r--r-----"; ck "sudoers: sem temporário sobrando" test ! -e "$SUDOERS.tmp"
  ck "visudo aprovou o temporário ANTES de valer" has "$LOG" "^visudo -cf $SUDOERS\\.tmp\$"; ck "dono = o admin" has "$LOG" '^chown opadm:opadm '
  ck "state: user" has "$W/state/admin" '^user=opadm$'; ck "state: fp" hasx "$W/state/admin" "fp=$FP1"; ck "state: epoch numérico" has "$W/state/admin" '^epoch=[0-9]+$'; ck "state 700" test "$(perm "$W/state")" = "drwx------"
  ck "nenhuma chave privada em lugar nenhum" hasnt "$OUT" 'PRIVATE'; ck "…nem no log dos stubs" hasnt "$LOG" 'PRIVATE'; ck "sem temporário do admin sobrando" test -z "$(ls "$W/state" | grep -v '^admin$')"
  sed 's/^epoch=.*/epoch=1000000000/' "$W/state/admin" > "$W/state/admin.x"; mv "$W/state/admin.x" "$W/state/admin"
  go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; ck "mesma chave de novo: rc 0 (idempotente)" rcis 0; ck "mesma chave: a hora da prova antiga é mantida" has "$W/state/admin" '^epoch=1000000000$'
  go "$1" admin --user opadm --pubkey-file "$T/K2.pub"; ck "chave DIFERENTE sem --replace: rc 2" rcis 2; ck "…não troca a chave" test "$(cat "$HOME_ADM/.ssh/authorized_keys")" = "$(cat "$T/K1.pub")"; ck "…e o state continua o da chave antiga" hasx "$W/state/admin" "fp=$FP1"
  go "$1" admin --user opadm --pubkey-file "$T/K2.pub" --replace; ck "--replace: rc 0" rcis 0; ck "--replace: chave nova instalada" test "$(cat "$HOME_ADM/.ssh/authorized_keys")" = "$(cat "$T/K2.pub")"
  ck "--replace: state com a chave nova" hasx "$W/state/admin" "fp=$FP2"; ck "--replace: hora da prova renovada (a prova antiga NÃO vale para a chave nova)" hasnt "$W/state/admin" '^epoch=1000000000$'
  world; go "$1" admin --user opadm --pubkey-file "$T/ECK.pub"; ck "ecdsa também entra" rcis 0; }
case_admin_refuse() { local a="--user opadm --pubkey-file $T/K1.pub"
  world; refused "nome root" "$1" "$MUT_ADMIN" admin --user root --pubkey-file "$T/K1.pub"; refused "nome runner" "$1" "$MUT_ADMIN" admin --user runner --pubkey-file "$T/K1.pub"; refused "nome dados" "$1" "$MUT_ADMIN" admin --user dados --pubkey-file "$T/K1.pub"
  refused "nome inválido" "$1" "$MUT_ADMIN" admin --user 'Bad User' --pubkey-file "$T/K1.pub"; refused "sem --user" "$1" "$MUT_ADMIN" admin --pubkey-file "$T/K1.pub"; refused "--user sem valor" "$1" "$MUT_ADMIN" admin --user
  refused "sem --pubkey-file" "$1" "$MUT_ADMIN" admin --user opadm; refused "arquivo inexistente" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/nao-existe.pub"
  refused "chave PRIVADA" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/K1"; refused "duas chaves" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/k-two.pub"
  refused "RSA" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/RSAK.pub"; refused "chave com opções (from=)" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/k-opt.pub"
  refused "só comentário" "$1" "$MUT_ADMIN" admin --user opadm --pubkey-file "$T/k-empty.pub"; refused "argumento desconhecido" "$1" "$MUT_ADMIN" admin $a --foo
  GETENT_FAIL=opadm cant "getent que falha" "$1" "$MUT_ADMIN" admin $a; }
case_admin_fail() { local st
  for st in useradd usermod passwd chown; do world; FAIL_STEP=$st go "$1" admin --user opadm --pubkey-file "$T/K1.pub"
    ck "falha em $st: rc 98" rcis 98; ck "falha em $st: diz falhou:" has "$ERR" '^LOCKDOWN-admin: falhou:'; ck "falha em $st: chave NÃO instalada" test ! -e "$HOME_ADM/.ssh/authorized_keys"; ck "falha em $st: sem state" test ! -e "$W/state/admin"; ck "falha em $st: sem sudoers" test ! -e "$SUDOERS"; done
  world; FAIL_STEP=visudo go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; ck "visudo reprova: rc 98" rcis 98; ck "visudo reprova: sudoers NÃO vale" test ! -e "$SUDOERS"; ck "visudo reprova: sem temporário" test ! -e "$SUDOERS.tmp"; ck "visudo reprova: sem state" test ! -e "$W/state/admin"
  world; FAKE_HOME=/ go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; ck "home '/': rc 98" rcis 98; ck "home '/': diz home-invalido" has "$ERR" 'falhou:home-invalido'; ck "home '/': sem state" test ! -e "$W/state/admin"
  world; FAKE_HOME=rel/home go "$1" admin --user opadm --pubkey-file "$T/K1.pub"; ck "home relativo: rc 98" rcis 98; ck "home relativo: sem state" test ! -e "$W/state/admin"
  # --replace que FALHA depois de trocar o authorized_keys: o state antigo (K1, com login provado) não pode sobreviver apontando para um nó que já aceita a K2.
  # O state é invalidado ANTES da troca; o rootcut seguinte recusa (sem admin gravado) e não escreve drop-in.
  for st in usermod passwd chown visudo; do prep "$1"; FAIL_STEP=$st go "$1" admin --user opadm --pubkey-file "$T/K2.pub" --replace
    ck "--replace falha em $st: rc 98" rcis 98; ck "--replace falha em $st: o state de K1 NÃO sobrevive" test ! -e "$W/state/admin"
    go "$1" rootcut; ck "--replace falha em $st: rootcut recusa (rc 2)" rcis 2; ck "--replace falha em $st: rootcut diz sem admin gravado" has "$ERR" 'recusado:sem admin gravado'; ck "--replace falha em $st: rootcut não recarrega o ssh" hasnt "$LOG" '^systemctl reload ssh$'; ck "--replace falha em $st: rootcut não escreve drop-in" test ! -e "$D_ROOT"; done
  # --replace que FUNCIONA: o login que estava no journal é da K1 e não vale para a K2; só um login novo com a K2 libera o rootcut
  prep "$1"; go "$1" admin --user opadm --pubkey-file "$T/K2.pub" --replace; ck "--replace ok: rc 0" rcis 0; go "$1" rootcut; ck "--replace ok: rootcut sem login da K2 recusa" rcis 2; ck "--replace ok: diz sem prova" has "$ERR" 'recusado:sem prova'
  login_line opadm "$FP2"; go "$1" rootcut; ck "--replace ok + login da K2 depois: rootcut passa" rcis 0; }
case_f2b_ok() { world; go "$1" fail2ban --ignoreip 198.51.100.7
  ck "fail2ban: rc 0" rcis 0; ck "diz a jail ativa e o ignoreip" has "$OUT" '^LOCKDOWN-fail2ban: ok jail sshd ativa; ignoreip=198\.51\.100\.7$'
  ck "drop-in: ignoreip = loopback + o mini" has "$J_F2B" '^ignoreip = 127\.0\.0\.1/8 ::1 198\.51\.100\.7$'; ck "drop-in: jail sshd habilitada" has "$J_F2B" '^enabled = true$'; ck "drop-in: seção [sshd]" has "$J_F2B" '^\[sshd\]$'
  ck "ordem: teste de config, enable, restart, jail respondendo, ignoreip lido de volta" order '^fail2ban-client -t$' '^systemctl enable fail2ban$' '^systemctl restart fail2ban$' '^fail2ban-client status sshd$' '^fail2ban-client get sshd ignoreip$'
  ck "binário já existia: sem apt" hasnt "$LOG" '^apt-get'
  world; go "$1" fail2ban --ignoreip 198.51.100.7,2001:db8::1; ck "lista de IPs: rc 0" rcis 0; ck "lista de IPs: todos no ignoreip" has "$J_F2B" '^ignoreip = 127\.0\.0\.1/8 ::1 198\.51\.100\.7 2001:db8::1$'
  world; ABSENT=" fail2ban-client " go "$1" fail2ban --ignoreip 198.51.100.7; ck "ausente: instala e sobe (rc 0)" rcis 0; ck "ausente: apt-get install -y fail2ban" has "$LOG" '^apt-get install -y fail2ban$'; }
case_f2b_refuse() { world
  refused "sem --ignoreip" "$1" "$MUT_F2B" fail2ban; refused "--ignoreip vazio" "$1" "$MUT_F2B" fail2ban --ignoreip ''; refused "--ignoreip lixo" "$1" "$MUT_F2B" fail2ban --ignoreip abc
  refused "--ignoreip com injeção" "$1" "$MUT_F2B" fail2ban --ignoreip '1.2.3.4;reboot'; refused "--ignoreip com espaço" "$1" "$MUT_F2B" fail2ban --ignoreip '1.2.3.4 5.6.7.8'; refused "argumento desconhecido" "$1" "$MUT_F2B" fail2ban --ignoreip 1.2.3.4 --foo
  # "a internet inteira" no ignoreip faria o fail2ban deixar de banir TODO MUNDO (e a leitura de volta passaria): endereço só de zeros ou máscara /0 são recusados, sozinhos ou dentro de uma lista
  refused "ignoreip 0.0.0.0/0" "$1" "$MUT_F2B" fail2ban --ignoreip 0.0.0.0/0; refused "ignoreip ::/0" "$1" "$MUT_F2B" fail2ban --ignoreip ::/0; refused "ignoreip 0.0.0.0" "$1" "$MUT_F2B" fail2ban --ignoreip 0.0.0.0
  refused "ignoreip ::" "$1" "$MUT_F2B" fail2ban --ignoreip ::; refused "ignoreip 1.2.3.4/0" "$1" "$MUT_F2B" fail2ban --ignoreip 1.2.3.4/0; refused "ignoreip 1.2.3.4/00" "$1" "$MUT_F2B" fail2ban --ignoreip 1.2.3.4/00
  refused "ignoreip lista com um 0.0.0.0/0" "$1" "$MUT_F2B" fail2ban --ignoreip 198.51.100.7,0.0.0.0/0
  ck "recusa não escreve drop-in" test ! -e "$J_F2B"; }
case_f2b_fail() { local st
  world; FAIL_STEP=apt ABSENT=" fail2ban-client " go "$1" fail2ban --ignoreip 198.51.100.7; ck "apt falha: rc 98" rcis 98; ck "apt falha: nenhum drop-in escrito" test ! -e "$J_F2B"; ck "apt falha: não chegou a subir nada" hasnt "$LOG" '^systemctl (enable|restart)'
  world; APT_NOBIN=1 ABSENT=" fail2ban-client " go "$1" fail2ban --ignoreip 198.51.100.7; ck "apt 'ok' sem binário: rc 98" rcis 98; ck "apt sem binário: nenhum drop-in escrito" test ! -e "$J_F2B"
  for st in f2b-test f2b-enable f2b-restart; do world; FAIL_STEP=$st go "$1" fail2ban --ignoreip 198.51.100.7; ck "falha em $st: rc 98" rcis 98; ck "falha em $st: drop-in removido" test ! -e "$J_F2B"; ck "falha em $st: fail2ban parado" has "$LOG" '^systemctl stop fail2ban$'; ck "falha em $st: diz o que ficou" has "$ERR" 'falhou:.*drop-in removido'; done
  world; F2B_NOJAIL=1 go "$1" fail2ban --ignoreip 198.51.100.7; ck "jail nunca responde: rc 98" rcis 98; ck "jail nunca responde: drop-in removido e fail2ban parado" has "$LOG" '^systemctl stop fail2ban$'; ck "jail nunca responde: sem drop-in" test ! -e "$J_F2B"
  # substr: a lista lida de volta traz 198.51.100.77, e o IP pedido é 198.51.100.7 (substring, não token): tem de falhar como "ausente"
  for st in empty fail other substr; do world; F2B_IGNORE=$st go "$1" fail2ban --ignoreip 198.51.100.7; ck "ignoreip '$st' lido de volta: rc 98" rcis 98; ck "ignoreip '$st': fail2ban parado" has "$LOG" '^systemctl stop fail2ban$'; ck "ignoreip '$st': drop-in removido" test ! -e "$J_F2B"; done
  world; mkdir -p "$W/etc/fail2ban/jail.d"; echo PREV > "$J_F2B"; FAIL_STEP=f2b-test go "$1" fail2ban --ignoreip 198.51.100.7; ck "drop-in anterior é restaurado na falha" test "$(cat "$J_F2B")" = PREV
  # o backup do drop-in anterior não pode ser gravado (symlink para diretório que não existe): 98 ANTES de sobrescrever, e o drop-in anterior continua o que era
  world; mkdir -p "$W/etc/fail2ban/jail.d"; echo PREV > "$J_F2B"; ln -s "$W/nao-existe/x" "$J_F2B.prev"; go "$1" fail2ban --ignoreip 198.51.100.7
  ck "backup do drop-in falha: rc 98" rcis 98; ck "backup falha: diz jail-backup" has "$ERR" 'falhou:jail-backup'; ck "backup falha: o drop-in anterior NÃO foi sobrescrito" test "$(cat "$J_F2B")" = PREV; ck "backup falha: não subiu nada" hasnt "$LOG" '^(apt-get|systemctl|fail2ban-client)'; }
case_ufw_ok() { world; go "$1" ufw --ssh-from any
  ck "ufw any: rc 0" rcis 0; ck "ordem: 22 liberada, lida de volta, política deny, rede armada, rede conferida, enable" order '^ufw allow 22/tcp$' '^ufw show added$' '^ufw default deny incoming$' '^ufw default allow outgoing$' '^systemd-run ' '^systemctl is-active gt-ufw-revert.timer$' '^ufw --force enable$'
  ck "rede de segurança: 10 min, ufw disable" has "$LOG" '^systemd-run --quiet --unit=gt-ufw-revert --on-active=10min /usr/sbin/ufw disable$'; ck "avisa da rede de segurança" has "$OUT" 'REDE DE SEGURANCA'; ck "manda provar por conexão NOVA" has "$OUT" 'conexao ssh NOVA'
  ck "ufw ficou ativo" exists "$W/ufw.on"; ck "rede segue armada até o confirm" exists "$W/timer.gt-ufw-revert"
  world; go "$1" ufw --ssh-from 198.51.100.0/24,2001:db8::/32; ck "faixas CIDR legítimas: rc 0" rcis 0; ck "faixa IPv4 /24 vira regra" has "$LOG" '^ufw allow from 198\.51\.100\.0/24 to any port 22 proto tcp$'
  world; go "$1" ufw --ssh-from 198.51.100.7,2001:db8::1; ck "lista: rc 0" rcis 0; ck "lista: regra do 1o IP" has "$LOG" '^ufw allow from 198\.51\.100\.7 to any port 22 proto tcp$'; ck "lista: regra do 2o IP" has "$LOG" '^ufw allow from 2001:db8::1 to any port 22 proto tcp$'; ck "lista: NÃO abre a 22 para todos" hasnt "$LOG" '^ufw allow 22/tcp$'
  world; ufw_on; go "$1" ufw --ssh-from any; ck "já ativo: rc 0" rcis 0; ck "já ativo: diz que já estava" has "$OUT" 'ja estava ativo'; ck "já ativo: diz que a política valeu NA HORA, sem rede de segurança" has "$OUT" 'deny incoming APLICADA na hora.*SEM rede de seguranca'; ck "já ativo: NÃO religa nem arma rede" hasnt "$LOG" '^(ufw --force enable|systemd-run)'; ck "já ativo: garante a regra da 22" has "$LOG" '^ufw allow 22/tcp$'; ck "já ativo: a 22 entra ANTES da política" order '^ufw allow 22/tcp$' '^ufw default deny incoming$'; }
case_ufw_refuse() { world
  refused "sem --ssh-from" "$1" "$MUT_UFW" ufw; refused "--ssh-from vazio" "$1" "$MUT_UFW" ufw --ssh-from ''; refused "--ssh-from lixo" "$1" "$MUT_UFW" ufw --ssh-from 'x;y'; refused "--ssh-from com injeção" "$1" "$MUT_UFW" ufw --ssh-from '1.2.3.4;reboot'; refused "argumento desconhecido" "$1" "$MUT_UFW" ufw --ssh-from any --foo
  refused "--ssh-from 0.0.0.0/0 (quem quer qualquer origem escreve any)" "$1" "$MUT_UFW" ufw --ssh-from 0.0.0.0/0; refused "--ssh-from ::/0" "$1" "$MUT_UFW" ufw --ssh-from ::/0; refused "--ssh-from lista com 0.0.0.0/0" "$1" "$MUT_UFW" ufw --ssh-from 198.51.100.7,0.0.0.0/0
  ABSENT=" ufw " cant "ufw ausente" "$1" "$MUT_UFW" ufw --ssh-from any
  # esconder o systemd-run só funciona onde o /usr/bin e o /bin do host não o têm (o mini). Num host Linux o PATH hermético (stubs:/usr/bin:/bin) ainda o acha: o caso não prova nada ali e é PULADO, em voz alta (medido no nó em 11/11)
  if PATH=/usr/bin:/bin command -v systemd-run >/dev/null 2>&1; then [ "$QUIET" = 1 ] || echo "skip systemd-run ausente: este host tem o systemd-run de verdade em /usr/bin ou /bin (AMBIENTE: o caso roda onde ele não existe, o mini)"
  else ABSENT=" systemd-run " cant "systemd-run ausente (sem rede de segurança, não liga)" "$1" "$MUT_UFW" ufw --ssh-from any; fi
  UFW_STATUS=garbage cant "ufw status ilegível" "$1" "$MUT_UFW" ufw --ssh-from any; UFW_STATUS=fail cant "ufw status que falha" "$1" "$MUT_UFW" ufw --ssh-from any; }
case_ufw_fail() { local st
  for st in allow default; do world; FAIL_STEP=$st go "$1" ufw --ssh-from any; ck "falha em $st: rc 98" rcis 98; ck "falha em $st: NÃO liga" hasnt "$LOG" '^ufw --force enable'; ck "falha em $st: ufw continua desligado" test ! -e "$W/ufw.on"; done
  world; UFW_DROP_RULE=1 go "$1" ufw --ssh-from any; ck "regra da 22 ausente na lista: rc 98" rcis 98; ck "regra ausente: NÃO liga" hasnt "$LOG" '^ufw --force enable'; ck "regra ausente: diz regra-22-ausente" has "$ERR" 'falhou:regra-22-ausente'
  world; UFW_DROP_RULE=1 go "$1" ufw --ssh-from 198.51.100.7; ck "regra ausente (lista): rc 98" rcis 98; ck "regra ausente (lista): NÃO liga" hasnt "$LOG" '^ufw --force enable'
  world; FAIL_STEP=systemd-run go "$1" ufw --ssh-from any; ck "rede não arma: rc 98" rcis 98; ck "rede não arma: NÃO liga" hasnt "$LOG" '^ufw --force enable'; ck "rede não arma: ufw continua desligado" test ! -e "$W/ufw.on"
  world; NO_ARM=1 go "$1" ufw --ssh-from any; ck "timer não ficou ativo: rc 98" rcis 98; ck "timer não ativo: NÃO liga" hasnt "$LOG" '^ufw --force enable'
  world; FAIL_STEP=enable go "$1" ufw --ssh-from any; ck "enable falha: rc 98" rcis 98; ck "enable falha: diz falhou:enable" has "$ERR" 'falhou:enable'
  world; UFW_NOSTICK=1 go "$1" ufw --ssh-from any; ck "enable 'ok' mas ufw não ficou ativo: rc 98" rcis 98; ck "…diz que não ficou ativo" has "$ERR" 'ufw-nao-ficou-ativo'; }
case_rootcut_ok() { prep "$1"; go "$1" rootcut
  ck "rootcut: rc 0" rcis 0; ck "drop-in: PermitRootLogin no" has "$D_ROOT" '^PermitRootLogin no$'; ck "diz que vale (efetivo)" has "$OUT" 'ok PermitRootLogin no \(efetivo\)'; ck "avisa da rede de segurança" has "$OUT" 'REDE DE SEGURANCA'; ck "manda provar por fora" has "$OUT" "ssh root@"
  ck "ordem: sshd -t, efetivo lido, rede armada, rede conferida, reload" order '^sshd -t$' '^sshd -T$' '^systemd-run ' '^systemctl is-active gt-rootcut-revert.timer$' '^systemctl reload ssh$'
  ck "rede: 10 min, remove o drop-in e recarrega" has "$LOG" "^systemd-run --quiet --unit=gt-rootcut-revert --on-active=10min /bin/sh -c rm -f $D_ROOT && systemctl reload ssh\$"
  ck "journal lido desde a hora da instalação do admin" has "$LOG" "^journalctl -u ssh -u ssh.socket --since @$(epoch_of) --no-pager -o cat\$"; ck "sudo do admin conferido" has "$LOG" '^sudo -n -l -U opadm$'
  ck "não mexe em ufw/fail2ban/pacotes" hasnt "$LOG" '^(ufw (allow|default|--force|disable)|apt-get|fail2ban-client -t)'; ck "rede segue armada até o confirm" exists "$W/timer.gt-rootcut-revert"
  prep "$1"; go "$1" rootcut --sem-trava1 "trava 1 sera aplicada depois (ga-qg1dw5z.1)"; ck "dados existe: --sem-trava1 é inócuo (rc 0)" rcis 0
  prep "$1"; grep -v '^dados:' "$W/passwd.db" > "$W/passwd.new"; mv "$W/passwd.new" "$W/passwd.db"; go "$1" rootcut --sem-trava1 "trava 1 sera aplicada depois (ga-qg1dw5z.1)"; ck "sem dados + motivo ≥10 letras: rc 0" rcis 0; ck "o motivo fica no log do nó" has "$LOG" '^logger -t gt-lockdown -- rootcut: rootcut sem a trava 1: trava 1 sera aplicada depois'; }
case_rootcut_refuse() { local m="$MUT_ROOT"
  world; ufw_on; f2b_up; refused "sem admin gravado" "$1" "$m" rootcut; ck "sem admin: sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; grep -v '^dados:' "$W/passwd.db" > "$W/passwd.new"; mv "$W/passwd.new" "$W/passwd.db"; refused "sem a trava 1 (sem dados) e sem motivo" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  refused "motivo curto demais" "$1" "$m" rootcut --sem-trava1 curto; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; rm -f "$W/ufw.on"; refused "ufw inativo" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; ABSENT=" fail2ban-client " refused "fail2ban ausente" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; rm -f "$W/f2b.up"; refused "jail sshd fora do ar" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; : > "$W/journal"; refused "journal sem nenhum login" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; : > "$W/journal"; login_line runner "$FP1"; refused "login de OUTRO usuário com a mesma chave" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; : > "$W/journal"; login_line opadm "$FP2"; refused "login do admin com OUTRA chave" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; printf 'Nov 11 21:00:00 no sshd[1]: Failed publickey for opadm from 203.0.113.9 port 5 ssh2: ED25519 %s\n' "$FP1" > "$W/journal"; refused "só tentativa FALHA do admin" "$1" "$m" rootcut
  prep "$1"; SUDO_MODE=denied refused "sudo do admin não vale" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; GETENT_FAIL=dados cant "getent dados que falha" "$1" "$m" rootcut
  prep "$1"; UFW_STATUS=garbage cant "ufw status ilegível" "$1" "$m" rootcut
  prep "$1"; FAIL_STEP=journal cant "journalctl que falha (não vira 'sem prova')" "$1" "$m" rootcut
  prep "$1"; SUDO_MODE=fail cant "sudo -l que falha" "$1" "$m" rootcut
  prep "$1"; awk -F= -v OFS== '$1=="fp"{$2="lixo"}1' "$W/state/admin" > "$W/state/admin.x"; mv "$W/state/admin.x" "$W/state/admin"; cant "state com fp quebrado" "$1" "$m" rootcut
  # (1b) o que o sshd ACEITA (authorized_keys) tem de ser a chave gravada no state; o state sozinho não prova nada sobre o arquivo
  AKF="$HOME_ADM/.ssh/authorized_keys"
  prep "$1"; cp "$T/K2.pub" "$AKF"; refused "authorized_keys com OUTRA chave que a gravada" "$1" "$m" rootcut; ck "…diz que a instalada difere" has "$ERR" 'chave instalada .* difere da gravada'; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; cat "$T/K1.pub" "$T/K2.pub" > "$AKF"; refused "authorized_keys com duas chaves (a gravada e outra)" "$1" "$m" rootcut; ck "…diz que tem mais de uma chave" has "$ERR" 'mais de uma chave'; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; echo '# só comentário' > "$AKF"; refused "authorized_keys só com comentário" "$1" "$m" rootcut; ck "…diz sem chave" has "$ERR" 'sem chave'; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; rm -f "$AKF"; refused "authorized_keys inexistente" "$1" "$m" rootcut; ck "…diz que não existe" has "$ERR" 'nao existe'; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; echo 'isto nao e uma chave' > "$AKF"; cant "authorized_keys ilegível para o ssh-keygen (não vira 'chave diferente' nem 'ok')" "$1" "$m" rootcut; ck "…sem drop-in" test ! -e "$D_ROOT"
  prep "$1"; GETENT_FAIL=opadm cant "getent do admin que falha" "$1" "$m" rootcut; ck "…diz o rc do getent" has "$ERR" 'getent passwd opadm rc=3'
  prep "$1"; grep -v '^opadm:' "$W/passwd.db" > "$W/passwd.new"; mv "$W/passwd.new" "$W/passwd.db"; refused "usuário admin sumiu do passwd" "$1" "$m" rootcut; ck "…diz que não existe" has "$ERR" 'nao existe'
  prep "$1"; awk -F: -v OFS=: '$1=="opadm"{$6="/"}1' "$W/passwd.db" > "$W/passwd.new"; mv "$W/passwd.new" "$W/passwd.db"; cant "home do admin '/' (não leio em lugar nenhum)" "$1" "$m" rootcut
  prep "$1"; ck "(controle) o mesmo mundo sem defeito passa" test "$(go "$1" rootcut; echo $RC)" = 0; }
case_rootcut_fail() { prep "$1"; local st
  FAIL_STEP=sshd-t go "$1" rootcut; ck "sshd -t reprova: rc 98" rcis 98; ck "sshd -t: drop-in removido" test ! -e "$D_ROOT"; ck "sshd -t: NÃO recarregou" hasnt "$LOG" '^systemctl reload ssh$'
  SSHD_IGNORE_DROPIN=1 go "$1" rootcut; ck "efetivo != no: rc 98" rcis 98; ck "efetivo != no: diz o efetivo" has "$ERR" 'falhou:efetivo=prohibit-password'; ck "efetivo != no: drop-in removido" test ! -e "$D_ROOT"; ck "efetivo != no: NÃO recarregou" hasnt "$LOG" '^systemctl reload ssh$'
  FAIL_STEP=systemd-run go "$1" rootcut; ck "rede não arma: rc 98" rcis 98; ck "rede não arma: drop-in removido" test ! -e "$D_ROOT"; ck "rede não arma: NÃO recarregou" hasnt "$LOG" '^systemctl reload ssh$'
  NO_ARM=1 go "$1" rootcut; ck "timer não ficou ativo: rc 98" rcis 98; ck "timer não ativo: drop-in removido" test ! -e "$D_ROOT"; ck "timer não ativo: NÃO recarregou" hasnt "$LOG" '^systemctl reload ssh$'
  FAIL_STEP=reload go "$1" rootcut; ck "reload falha: rc 98" rcis 98; ck "reload falha: drop-in removido" test ! -e "$D_ROOT"; }
case_confirm() { world; ufw_on; : > "$W/timer.gt-ufw-revert"; go "$1" confirm ufw
  ck "confirm ufw: rc 0" rcis 0; ck "confirm ufw: cancela a rede" has "$LOG" '^systemctl stop gt-ufw-revert.timer$'; ck "confirm ufw: rede desarmada" test ! -e "$W/timer.gt-ufw-revert"
  world; : > "$W/timer.gt-ufw-revert"; go "$1" confirm ufw; ck "ufw desligado (a rede disparou): rc 2" rcis 2; ck "…não confirma nada" hasnt "$LOG" '^systemctl stop gt-ufw-revert.timer$'; ck "…a rede continua como estava" exists "$W/timer.gt-ufw-revert"
  world; ufw_on; UFW_STATUS=garbage go "$1" confirm ufw; ck "ufw ilegível: rc 3" rcis 3
  world; ufw_on; : > "$W/timer.gt-ufw-revert"; FAIL_STEP=timer-stuck go "$1" confirm ufw; ck "timer que não para: rc 98" rcis 98; ck "timer que não para: diz timer-ainda-armado" has "$ERR" 'timer-ainda-armado'
  prep "$1"; go "$1" rootcut; go "$1" confirm rootcut; ck "confirm rootcut: rc 0" rcis 0; ck "confirm rootcut: cancela a rede" has "$LOG" '^systemctl stop gt-rootcut-revert.timer$'; ck "confirm rootcut: rede desarmada" test ! -e "$W/timer.gt-rootcut-revert"
  prep "$1"; go "$1" rootcut; SSHD_IGNORE_DROPIN=1 go "$1" confirm rootcut; ck "efetivo != no (o root voltou): rc 2" rcis 2; ck "…NÃO cancela a rede" hasnt "$LOG" '^systemctl stop gt-rootcut-revert.timer$'; ck "…a rede continua armada" exists "$W/timer.gt-rootcut-revert"
  # sshd -T sem resposta é "não consegui ler" (rc 3), não "o root voltou" (rc 2): nada é confirmado e a rede continua armada
  SSHD_T=empty go "$1" confirm rootcut; ck "efetivo ilegível: rc 3 (não confirma às cegas)" rcis 3; ck "…diz nao-consegui" has "$ERR" '^LOCKDOWN-confirm: nao-consegui:'; ck "…NÃO cancela a rede" hasnt "$LOG" '^systemctl stop gt-rootcut-revert.timer$'; ck "…a rede continua armada" exists "$W/timer.gt-rootcut-revert"
  go "$1" confirm; ck "confirm sem alvo: rc 2" rcis 2; go "$1" confirm xpto; ck "confirm alvo desconhecido: rc 2" rcis 2; }
case_undo() { world; ufw_on; : > "$W/timer.gt-ufw-revert"; go "$1" undo ufw; ck "undo ufw: rc 0" rcis 0; ck "undo ufw: ufw disable" has "$LOG" '^ufw disable$'; ck "undo ufw: ufw desligado" test ! -e "$W/ufw.on"; ck "undo ufw: rede desarmada" test ! -e "$W/timer.gt-ufw-revert"
  prep "$1"; go "$1" rootcut; go "$1" undo rootcut; ck "undo rootcut: rc 0" rcis 0; ck "undo rootcut: drop-in removido" test ! -e "$D_ROOT"; ck "undo rootcut: recarregou" has "$LOG" '^systemctl reload ssh$'; ck "undo rootcut: rede desarmada" test ! -e "$W/timer.gt-rootcut-revert"
  go "$1" undo; ck "undo sem alvo: rc 2" rcis 2; go "$1" undo xpto; ck "undo alvo desconhecido: rc 2" rcis 2; }
case_nonroot() { world; local c
  for c in "admin --user opadm --pubkey-file $T/K1.pub" "fail2ban --ignoreip 198.51.100.7" "ufw --ssh-from any" "rootcut" "confirm ufw" "undo ufw"; do
    # shellcheck disable=SC2086
    FAKE_UID=1000 refused "não-root ($c)" "$1" '^(useradd|usermod|passwd|visudo|apt-get|ufw (allow|default|--force|disable)|systemd-run|systemctl (stop|reload|restart|enable))' $c; done
  # um ck por afirmação: um `&&` fora do ck descartaria tudo menos o primeiro teste (o ck sempre devolve 0)
  ck "não-root: nenhum state" test ! -e "$W/state/admin"; ck "não-root: nenhum drop-in do rootcut" test ! -e "$D_ROOT"; ck "não-root: nenhum sudoers" test ! -e "$SUDOERS"; }

for c in ${SELFTEST_CASES:-usage status origins admin_ok admin_refuse admin_fail f2b_ok f2b_refuse f2b_fail ufw_ok ufw_refuse ufw_fail rootcut_ok rootcut_refuse rootcut_fail confirm undo nonroot}; do "case_$c" "$T/H.sh"; done

M=0
mutant() { # nome expr-sed caso
  [ "$MUTANTES" = 1 ] || return 0
  local f="$T/m-$1.sh"; sed "$2" "$T/H.sh" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1))
  if cmp -s "$T/H.sh" "$f"; then echo "FAIL $1: o sed não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null || { echo "FAIL $1: mutante com erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$3" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$3' reprova o mutante)"; else echo "FAIL $1: o caso '$3' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutant H1-visudo-nao-consultado 's/visudo -cf "\$SF.tmp" >\/dev\/null 2>&1 || { rm -f "\$SF.tmp"; cleanup_t; die visudo; }/true/' admin_fail
mutant H2-chave-diferente-sobrescreve 's/\[ "\$replace" = 1 \] || /true || /' admin_ok
mutant H3-nome-reservado-passa 's/root|runner|dados|nobody/NEVERx|nobody/' admin_refuse
mutant H4-senha-nao-travada-erro-ignorado 's/die passwd-l; }/true; }/' admin_fail
mutant H5-fail2ban-sem-ignoreip 's/valid_srcs "\$ign" || nope/true || nope/' f2b_refuse
mutant H6-fail2ban-falha-deixa-rodando 's/; systemctl stop fail2ban >\/dev\/null 2>&1; }/; }/' f2b_fail
mutant H7-ignoreip-nao-conferido 's/ || { undo_f2b; die "ignoreip-ausente:\$ip (fail2ban parado)"; }/ || true/' f2b_fail
mutant H8-liga-ufw-sem-a-regra-da-22 's/die regra-22-ausente ;;/true ;;/' ufw_fail
mutant H9-liga-ufw-sem-rede-armada 's/ || die rede-nao-armada$/ || true/' ufw_fail
mutant H10-porta-errada 's/ufw allow 22\/tcp >/ufw allow 2222\/tcp >/' ufw_ok
mutant H11-ufw-ilegivel-vira-inativo 's/\*) return 3 ;; esac/*) return 1 ;; esac/' ufw_refuse
mutant H12-ufw-que-falha-vira-inativo 's/st=\$(ufw status 2>\/dev\/null) || return 3/st=$(ufw status 2>\/dev\/null) || return 1/' ufw_refuse
mutant H13-origem-lixo-aceita 's/\]\] || return 1/]] || true/' ufw_refuse
mutant H14-rootcut-sem-prova-de-login 's/\[ "\$n" -ge 1 \] || nope "sem prova/true || nope "sem prova/' rootcut_refuse
mutant H15-prova-sem-conferir-usuario 's/index(\$0,"Accepted publickey for " u " from ") && //' rootcut_refuse
mutant H16-prova-sem-conferir-chave 's/ && index(\$0,f) {c++}/ {c++}/' rootcut_refuse
mutant H17-journal-sem-marco-da-instalacao 's/ --since "@\$epoch"//' rootcut_ok
mutant H18-rootcut-sem-ufw 's/1) nope "ufw inativo/1) true "ufw inativo/' rootcut_refuse
mutant H19-rootcut-sem-jail 's/ || nope "jail sshd do fail2ban nao responde[^"]*"/ || true/' rootcut_refuse
mutant H20-trava1-override-sem-motivo 's/if \[ -n "\$nota1" \] && \[ "\${#nota1}" -ge 10 \]; then/if true; then/' rootcut_refuse
mutant H21-getent-que-falha-vira-sem-dados 's/\*) cant "getent passwd dados rc=\$n" ;;/*) ;;/' rootcut_refuse
mutant H22-journal-que-falha-vira-sem-prova 's/ || cant "journalctl"/ || true/' rootcut_refuse
mutant H23-efetivo-nao-conferido 's/\[ "\$eff" = no \] || { rm -f "\$D"; die "efetivo/true || { rm -f "$D"; die "efetivo/' rootcut_fail
mutant H24-rede-nao-armada-deixa-o-drop-in 's/is-active gt-rootcut-revert.timer >\/dev\/null 2>&1 || { rm -f "\$D"; die/is-active gt-rootcut-revert.timer >\/dev\/null 2>\&1 || { die/' rootcut_fail
mutant H25-rede-de-seguranca-longa 's/--on-active=10min \/bin\/sh/--on-active=10h \/bin\/sh/' rootcut_ok
mutant H26-confirm-rootcut-as-cegas 's/\[ "\$eff" = no \] || nope "permitrootlogin efetivo/true || nope "permitrootlogin efetivo/' confirm
mutant H27-confirm-ufw-desligado 's/1) nope "o ufw esta desligado/1) true "o ufw esta desligado/' confirm
mutant H28-zgrep-que-falha-vira-vazio 's/\*) cant "zgrep rc=\$rc" ;;/*) say "vazio" ;;/' origins
mutant H29-nao-checa-root 's/^need_root() { .*$/need_root() { true; }/' nonroot
mutant H30-replace-que-falha-deixa-o-state-antigo 's/then rm -f "\$STATE\/admin" || { cleanup_t; die state-invalida; }; fi/then true; fi/' admin_fail
mutant H31-rootcut-confia-no-state-sem-ler-o-authorized_keys 's/\[ "\$instfp" = "\$fp" \] || nope .*$/true/' rootcut_refuse
mutant H32-rootcut-aceita-duas-chaves 's/ = 1 \] || nope "\$AK tem mais de uma chave/ -ge 1 ] || nope "$AK tem mais de uma chave/' rootcut_refuse
mutant H33-rootcut-aceita-home-barra 's/ in \/|\/root|"") cant "home do admin invalido/ in \/root|"") cant "home do admin invalido/' rootcut_refuse
mutant H34-getent-do-admin-que-falha-passa 's/\*) cant "getent passwd \$user rc=\$n" ;;/*) ;;/' rootcut_refuse
mutant H35-admin-sumido-vira-nao-consegui 's/2) nope "usuario admin \$user nao existe[^"]*" ;;/2) ;;/' rootcut_refuse
mutant H36-ignoreip-so-de-zeros-aceito '/\^\[0\.:\]+\$/d' f2b_refuse
mutant H37-mascara-zero-aceita '/\^0+\$/d' f2b_refuse
mutant H38-ignoreip-substring-vale 's/if (t==ip) f=1/if (index(t,ip)) f=1/' f2b_fail
mutant H39-backup-do-drop-in-ignorado 's/ || die jail-backup//' f2b_fail
mutant H40-ufw-ja-ativo-sem-avisar 's/SEM rede de seguranca/com rede de seguranca/' ufw_ok
mutant H41-confirm-rootcut-com-efetivo-ilegivel 's/\[ -n "\$eff" \] || cant "sshd -T ilegivel.*$/true/' confirm
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
