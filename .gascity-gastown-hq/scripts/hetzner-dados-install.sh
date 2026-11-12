#!/bin/bash
# hetzner-dados-install.sh — instalador de ROOT (uma vez, idempotente) da trava 1: usuário `dados`, staging em tmpfs, wrapper, canal do mini e varredura (ga-qg1dw5z.1).
#
# ## Contents
#   Uso · O que instala · Códigos de saída
#
# USO (como root no nó, com este repo em $WA; sem comando de root improvisado: o que o runbook pede é este script):
#   hetzner-dados-install.sh apply --pubkey-file <mini.pub> [--entrypoint <nome>]... [--code-dir <dir> --code-sha <sha>] [--runner runner] [--stage-size 8g]
#   hetzner-dados-install.sh --check      confere o contrato inteiro como root e imprime `GTD-CHECK: <item> ok|FALHOU|nao-consegui` (rc 0 só com tudo ok)
# O QUE INSTALA: usuário `dados` (senha travada, shell real, home 0700, grupo próprio, runner FORA dele) · /srv/gtdados tmpfs (fstab: size=, 0700 dados, noexec,nosuid,nodev) · /usr/local/sbin/gt-dados-{run,ingest,sweep}
#   · /opt/gt-dados/app/bin/<entrypoint> (árvore de ROOT, ninguém mais escreve; a de `--code-dir` só entra com o HEAD igual a `--code-sha` e árvore limpa) + /etc/gt-dados/entrypoints
#   · /etc/ssh/authorized_keys.d/dados (de ROOT: `restrict,command="gt-dados-ingest"`) + drop-in sshd `Match User dados` · /etc/sudoers.d/gt-dados-run (UMA linha por entrypoint, sem curinga) · gt-dados-sweep.timer diário.
#   sshd só recarrega DEPOIS de `sshd -t` e de `sshd -T -C` provar que `dados` usa o arquivo de ROOT e o runner NÃO; qualquer reprovação desfaz o drop-in. sudoers só entra depois de `visudo -cf`.
# CÓDIGOS: 0 · 64 uso/não é root · 98 um passo falhou (`GTD-INSTALL: falhou:<passo>`; o que já estava no nó não é apagado, exceto o drop-in do sshd reprovado)
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
DU=dados; SBIN=/usr/local/sbin; ETC=/etc/gt-dados; OPT=/opt/gt-dados; STAGE=/srv/gtdados; DHOME=/home/dados; SSHD_D=/etc/ssh/sshd_config.d; AKDIR=/etc/ssh/authorized_keys.d
SUDOERS=/etc/sudoers.d/gt-dados-run; FSTAB=/etc/fstab; UNITS=/etc/systemd/system; LOGF=/var/log/gt-dados-sweep.log
SRC=$(cd "$(dirname "$0")" && pwd); RUNNER=runner
die() { echo "GTD-INSTALL: falhou:$1" >&2; exit 98; }
chk() { local n=$1 rc; shift; "$@" > /dev/null 2>&1; rc=$?; case $rc in 0) echo "GTD-CHECK: $n ok" ;; 127) echo "GTD-CHECK: $n nao-consegui"; [ "$CH" = 1 ] || CH=2 ;; *) echo "GTD-CHECK: $n FALHOU"; CH=1 ;; esac; }
owned() { [ "$(stat -c '%U:%G %a' "$1" 2> /dev/null)" = "$2" ]; }
sshd_for() { sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2> /dev/null; }
# cada teste é uma função: rc 0 ok · 127 ferramenta ausente (nao-consegui) · outro rc = FALHOU
t_locked() { [ "$(passwd -S "$DU" | cut -d' ' -f2)" = L ]; }
t_shell() { case "$(getent passwd "$DU" | cut -d: -f7)" in ''|*nologin|*/false) return 1 ;; esac; }
t_grupos() { [ "$(id -nG "$DU")" = "$DU" ]; }
t_runner() { ! id -nG "$RUNNER" | tr ' ' '\n' | grep -qx "$DU"; }
t_keys() { [ "$(stat -c '%U %a' "$AKDIR/$DU")" = "root 640" ] && grep -Eq "^restrict,command=\"$SBIN/gt-dados-ingest\" ssh-|^restrict,command=\"$SBIN/gt-dados-ingest\" ecdsa-" "$AKDIR/$DU"; }
t_sshd_d() { sshd_for "$DU" | grep -qx "authorizedkeysfile $AKDIR/$DU"; }
t_sshd_r() { ! sshd_for "$RUNNER" | grep -q '^authorizedkeysfile .*authorized_keys.d'; }
t_tree() { [ -z "$(find "$OPT" \( -not -user root -o -perm -020 -o -perm -002 \) -print -quit)" ]; }
t_sudo_strict() { ! grep -E '^[^#]' "$SUDOERS" | grep -Ev "^$RUNNER ALL=\(root\) NOPASSWD: $SBIN/gt-dados-run [a-z0-9_.-]+\$" | grep -q .; }
t_sudo_list() { [ "$(grep -E '^[^#]' "$SUDOERS" | sed 's/.* //' | sort)" = "$(sort "$ETC/entrypoints")" ]; }
t_stage() { local o; mountpoint -q "$STAGE" && o=$(findmnt -no FSTYPE,OPTIONS "$STAGE") && [ "${o%% *}" = tmpfs ] && case ",${o#* }," in *,noexec,*) case ",${o#* }," in *,nosuid,*) case ",${o#* }," in *,nodev,*) return 0 ;; esac ;; esac ;; esac; return 1; }
t_swap() { [ -z "$(swapon --noheadings --show)" ]; }
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
[ "${1:-}" = apply ] && [ "$(id -u)" = 0 ] || { echo "uso (como root): $0 apply --pubkey-file <f.pub> [...] | --check" >&2; exit 64; }
shift; PUB=""; ENTS="synth"; CODE=""; SHA=""; SIZE=8g
while [ $# -gt 0 ]; do case $1 in
  --pubkey-file) PUB=${2:-}; shift 2 ;; --entrypoint) ENTS="$ENTS ${2:-}"; shift 2 ;; --code-dir) CODE=${2:-}; shift 2 ;; --code-sha) SHA=${2:-}; shift 2 ;;
  --runner) RUNNER=${2:-}; shift 2 ;; --stage-size) SIZE=${2:-}; shift 2 ;; *) echo "argumento desconhecido: $1" >&2; exit 64 ;; esac; done
# vazio → recusa (nunca "sem chave = qualquer chave"); chave com opções (command=, no-restrict) também: as opções são só as nossas
[ -n "$PUB" ] && [ "$(grep -c . "$PUB" 2> /dev/null)" = 1 ] && grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$' "$PUB" && ssh-keygen -l -f "$PUB" > /dev/null 2>&1 || die pubkey
for e in $ENTS; do [[ $e =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || die "entrypoint-invalido:$e"; done
[[ $SIZE =~ ^[1-9][0-9]*[mg]$ ]] || die stage-size
[ -z "$CODE" ] || { [ -n "$SHA" ] && [ "$(git -C "$CODE" rev-parse HEAD 2> /dev/null)" = "$SHA" ] && [ -z "$(git -C "$CODE" status --porcelain 2> /dev/null || echo ?)" ]; } || die code-dir-nao-e-o-sha-limpo
# 1. usuário: sem skel (-M), senha travada, shell REAL (nologin quebraria o forced command: o sshd roda o command= pelo shell), home 0700, grupo próprio
getent passwd "$DU" > /dev/null || useradd -M -d "$DHOME" -s /bin/bash -U -c "gt dados (trava 1)" "$DU" || die useradd
usermod -L "$DU" || die passwd-lock
install -d -o "$DU" -g "$DU" -m 0700 "$DHOME" || die home
[ "$(id -nG "$DU")" = "$DU" ] || die grupos-extras-do-dados
id -nG "$RUNNER" | tr ' ' '\n' | grep -qx "$DU" && die runner-no-grupo-dados
# 2. árvore de root: nada que o runner edite roda como dados
install -d -o root -g root -m 0755 "$OPT" "$OPT/app" "$OPT/app/bin" "$ETC" || die dirs
[ -z "$CODE" ] || rsync -a --delete --chown=root:root --chmod=Dgo-w,Fgo-w --exclude=.git "$CODE"/ "$OPT/app/" || die rsync-code
install -d -o root -g root -m 0755 "$OPT/app/bin" && install -o root -g root -m 0755 "$SRC/hetzner-dados-synth.sh" "$OPT/app/bin/synth" || die synth
for e in $ENTS; do [ -f "$OPT/app/bin/$e" ] && [ ! -L "$OPT/app/bin/$e" ] || die "entrypoint-ausente:$e"; done
# link que aponta para fora da árvore de root deixaria o runner trocar o que roda como dados; find que falha → recusa, nunca "sem links"
LINKS=$(find "$OPT" -type l) || die find-links
while IFS= read -r l; do [ -z "$l" ] || case $(readlink -f "$l") in "$OPT"/*) ;; *) die "link-fora-da-arvore:$l" ;; esac; done <<< "$LINKS"
printf '%s\n' $ENTS | sort -u > "$ETC/entrypoints.new" && chmod 0644 "$ETC/entrypoints.new" && mv "$ETC/entrypoints.new" "$ETC/entrypoints" || die entrypoints
for p in run ingest sweep; do install -o root -g root -m 0755 "$SRC/hetzner-dados-$p.sh" "$SBIN/gt-dados-$p" || die "install-$p"; done
# 3. canal do mini: chave de ROOT (o dados não regrava a própria chave) + drop-in; só recarrega o sshd com a prova do `sshd -T`; reprovou → desfaz o drop-in
install -d -o root -g root -m 0755 "$AKDIR" || die akdir
printf 'restrict,command="%s/gt-dados-ingest" %s\n' "$SBIN" "$(cat "$PUB")" > "$AKDIR/$DU.new" && chown "root:$DU" "$AKDIR/$DU.new" && chmod 0640 "$AKDIR/$DU.new" && mv "$AKDIR/$DU.new" "$AKDIR/$DU" || die authorized-keys
DROP="$SSHD_D/50-gt-dados.conf"; [ -f "$DROP" ] && cp -p "$DROP" "$DROP.prev"
printf 'Match User %s\n    AuthorizedKeysFile %s/%s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    AllowTcpForwarding no\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    PermitUserRC no\n' "$DU" "$AKDIR" "$DU" > "$DROP" || die dropin
undo() { if [ -f "$DROP.prev" ]; then mv "$DROP.prev" "$DROP"; else rm -f "$DROP"; fi; die "$1 (drop-in do sshd desfeito)"; }
sshd -t || undo sshd-t
sshd_for "$DU" | grep -qx "authorizedkeysfile $AKDIR/$DU" || undo sshd-dados-nao-usa-o-arquivo-de-root
sshd_for "$RUNNER" | grep -q '^authorizedkeysfile .*authorized_keys.d' && undo sshd-runner-afetado
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
