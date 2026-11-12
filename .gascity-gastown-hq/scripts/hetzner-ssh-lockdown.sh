#!/bin/bash
# hetzner-ssh-lockdown.sh — trava 2 do Hetzner (ga-qg1dw5z.2): fecha o ssh do nó (admin com sudo, fail2ban, ufw, root sem login) SEM perder o servidor. Roda como ROOT, NO NÓ.
#
# ## Contents
#   Por quê · Uso · Ordem · Redes de segurança · Códigos · O que este script NÃO faz
#
# POR QUÊ: medido 11/11 — a chave do runner (hetzner_teste_urblink, só no mini) entra como ROOT, ufw e fail2ban estavam inativos, a 22 em 0.0.0.0. Cada passo é um comando de root que, errado,
#   deixa o servidor inalcançável (só o console da Hetzner volta). Por isso é script versionado + selftest hermético (hetzner-ssh-lockdown.selftest.sh), nunca comando improvisado ao vivo,
#   e cada passo só avança com a PROVA do anterior. Quem entrega o script ao nó é o dog do mini (tem a chave de root); a instalação está em docs/runbooks/hetzner-ssh-lockdown.md.
# USO (como root no nó; cada subcomando imprime `LOCKDOWN-<fase>: ...` e sai com os códigos abaixo):
#   status                                    só lê: sshd (permitrootlogin), ufw, fail2ban, admin gravado.
#   origins                                   só lê: de que IP o runner/root entram (auth.log, só contagem). Responde "o IP do mini é fixo?" antes de qualquer allowlist.
#   admin --user NOME --pubkey-file ARQ       cria o usuário admin (sudo, senha travada) e instala SÓ a chave PÚBLICA (ed25519/ecdsa, sem opções). A privada nunca passa por aqui.
#   fail2ban --ignoreip IP[,IP...]            instala/ativa fail2ban com jail sshd; o ignoreip (o IP do mini) é OBRIGATÓRIO, senão um ban cortaria o túnel e o espelho.
#   ufw --ssh-from any|IP[,IP...]             default deny incoming + regra da 22 ANTES do enable; arma a rede de segurança (ufw desliga sozinho em 10 min) e só então liga. Com o ufw JÁ ativo não há enable nem rede: a política muda na hora.
#   rootcut [--sem-trava1 "motivo"]           PermitRootLogin no, SÓ com as 5 provas abaixo; arma a rede de segurança (reabre o root em 10 min) e recarrega o sshd.
#   confirm ufw|rootcut                       cancela a rede de segurança do passo (rode DEPOIS de provar por uma conexão NOVA).
#   undo ufw|rootcut                          desfaz o passo à mão (console da Hetzner ou a sessão de root ainda aberta).
# ORDEM (a trava 1, ga-qg1dw5z.1, precisa do root atual: aplique-a ANTES do rootcut): admin → prova do admin por 2ª sessão NOVA → fail2ban → ufw (+confirm) → rootcut (+confirm).
#   O rootcut recusa sem: (1) admin gravado E a chave que está no authorized_keys dele é a gravada (uma só); (2) usuário `dados` da trava 1 (ou --sem-trava1 com motivo, que fica no log); (3) ufw ativo; (4) jail sshd do fail2ban de pé;
#   (5) LOGIN REAL do admin com a chave gravada, lido do journal do sshd depois da instalação (o agente não tem a chave privada: quem entra é o Athos, e o journal é a prova) + sudo do admin válido.
# REDES DE SEGURANÇA: ufw e rootcut armam um timer systemd (gt-ufw-revert / gt-rootcut-revert, 10 min); sem timer armado, o passo NÃO roda. O ufw arma antes do enable; o rootcut escreve o drop-in, confere o efetivo, arma e só então recarrega (o sshd só lê o drop-in no reload: o corte nunca vale sem o timer). `confirm` o cancela.
# CÓDIGOS: 0 ok · 2 recusado (pré-condição/uso; NADA foi mudado) · 3 não consegui ler (NADA foi mudado; nunca vira "vazio") · 98 um passo falhou (o que ficou no nó está na mensagem; o estado perigoso é desfeito).
# NÃO FAZ: firewall da Hetzner Cloud (sem token no Bitwarden hoje), a chave privada do admin (fica no Bitwarden do Athos), a trava 1 (usuário `dados`) e a auditoria (trava 3). `sshd -T` (sem -C) não enxerga blocos Match: o nó não tem nenhum (medido 11/11) e a prova final é o `ssh root@` recusando.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ETC=/etc
LOGDIR=/var/log
STATE=/var/lib/gt-lockdown
WAIT_TRIES=10
PHASE=uso
say() { echo "LOCKDOWN-$PHASE: $*"; }
die() { echo "LOCKDOWN-$PHASE: falhou:$1" >&2; exit 98; }
nope() { echo "LOCKDOWN-$PHASE: recusado:$1" >&2; exit 2; }
cant() { echo "LOCKDOWN-$PHASE: nao-consegui:$1" >&2; exit 3; }
note() { logger -t gt-lockdown -- "$PHASE: $*" 2>/dev/null; return 0; }
need_val() { [ "$1" -ge 2 ] || nope "falta o valor de $2"; }
# lista de origens: IPv4/IPv6 com /máscara opcional, separados por vírgula. O valor vai parar numa regra de firewall e num arquivo de config: qualquer outra coisa é recusada.
valid_srcs() {
  local s; local -a a
  [ -n "$1" ] || return 1
  IFS=, read -r -a a <<< "$1"
  for s in "${a[@]}"; do
    # endereço só de zeros (0.0.0.0, ::, 0:0:0:0:0:0:0:0) ou máscara /0 (também /00, /000) é a internet inteira: no ignoreip o fail2ban deixaria de banir TODO MUNDO, na regra da 22 seria `any` sem dizer; quem quer "qualquer origem" no ufw escreve `any`
    case "$s" in */*) [[ "${s#*/}" =~ ^0+$ ]] && return 1 ;; esac
    [[ "${s%%/*}" =~ ^[0.:]+$ ]] && return 1
    [[ "$s" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "$s" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]] || return 1
  done
}
ufw_active() { # rc 0 ativo · 1 inativo · 3 não consegui ler (nunca vira "inativo")
  local st
  # vazio → não existe (ufw ausente): 3; falhou/ilegível → 3; só "Status: active"/"Status: inactive" têm resposta
  st=$(ufw status 2>/dev/null) || return 3
  case "$st" in "Status: active"*) return 0 ;; "Status: inactive"*) return 1 ;; *) return 3 ;; esac
}
sshd_root_eff() { # imprime o permitrootlogin EFETIVO (sshd -T); vazio se não deu para ler
  # vazio → sshd -T sem a chave (impresso vazio): quem chama trata como "?"; falhou/ilegível → idem, nunca "no"
  sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}'
}
need_root() { [ "$(id -u)" = 0 ] || nope "precisa de root"; }
# o temporário do `admin` só tem o k.pub (chave PÚBLICA): sem remoção recursiva, o rmdir só leva o diretório se estiver vazio
cleanup_t() { rm -f "$T/k.pub"; rmdir "$T" 2>/dev/null; return 0; }

cmd_status() {
  PHASE=status
  local v u f
  v=$(sshd_root_eff)
  say "sshd permitrootlogin=${v:-?}"
  # vazio → ufw ausente ou ilegível: "?" (nunca "inativo")
  ufw_active; case $? in 0) u=ativo ;; 1) u=inativo ;; *) u="?" ;; esac
  say "ufw=$u"
  # vazio → comando ausente ("ausente"); falhou → a jail sshd não respondeu ("sem-jail" = jail inexistente OU servidor fora do ar: o rc do fail2ban-client não distingue, então NÃO é prova de que falta a jail); só rc 0 é "ativo"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client status sshd >/dev/null 2>&1; then f=ativo; else f=sem-jail; fi
  else f=ausente; fi
  say "fail2ban=$f"
  # vazio → arquivo ausente: "nenhum"; falhou/ilegível → "?"
  if [ -e "$STATE/admin" ]; then
    v=$(awk -F= '$1=="user"{print $2}' "$STATE/admin" 2>/dev/null) && say "admin=${v:-?}" || say "admin=?"
  else say "admin=nenhum"; fi
  exit 0
}

cmd_origins() {
  PHASE=origins
  local out rc
  # vazio → nenhuma entrada aceita no log: "vazio" (rc 0); falhou/ilegível → nao-consegui (rc 3), nunca "vazio"
  [ -r "$LOGDIR/auth.log" ] || cant "auth.log ilegivel"
  out=$(zgrep -h -E 'sshd.*Accepted publickey for ' "$LOGDIR"/auth.log* 2>/dev/null); rc=$?
  case $rc in
    0) printf '%s\n' "$out" | awk '{ for (i=1;i<=NF;i++) if ($i=="for") { u=$(i+1); ip=$(i+3); c[u " " ip]++ } } END { for (k in c) { split(k,p," "); printf "LOCKDOWN-origins: user=%s ip=%s n=%d\n", p[1], p[2], c[k] } }' | sort ;;
    1) say "vazio (nenhum Accepted publickey no log)" ;;
    *) cant "zgrep rc=$rc" ;;
  esac
  exit 0
}

cmd_admin() {
  PHASE=admin
  local user="" keyf="" replace=0 keys want have fp T H AK SF rc existing=0 epoch old_fp old_user old_epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) need_val $# "$1"; user=$2; shift 2 ;;
      --pubkey-file) need_val $# "$1"; keyf=$2; shift 2 ;;
      --replace) replace=1; shift ;;
      *) nope "argumento desconhecido: $1" ;;
    esac
  done
  need_root
  [[ "$user" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || nope "--user invalido"
  case "$user" in root|runner|dados|nobody|daemon|www-data|ubuntu) nope "nome reservado: $user" ;; esac
  # vazio → arquivo sem linha de chave: recusa; falhou/ilegível → recusa antes de tocar em qualquer coisa
  [ -f "$keyf" ] && [ -r "$keyf" ] || nope "--pubkey-file ilegivel"
  keys=$(awk '!/^[[:space:]]*(#|$)/' "$keyf") || cant "leitura do pubkey-file"
  case "$keys" in *PRIVATE*) nope "o arquivo parece conter uma chave PRIVADA; so a publica entra aqui" ;; esac
  [ -n "$keys" ] || nope "pubkey-file sem chave"
  [ "$(printf '%s\n' "$keys" | awk 'END{print NR}')" = 1 ] || nope "exatamente UMA chave publica"
  [[ "$keys" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp256)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]] || nope "so ed25519/ecdsa, sem opcoes (from=, command=)"
  mkdir -p "$STATE" && chmod 700 "$STATE" || die state-dir
  T=$(mktemp -d "$STATE/t.XXXXXX") || die mktemp
  printf '%s\n' "$keys" > "$T/k.pub"
  # vazio/falhou → fingerprint que não é SHA256:<43>: recusa (a chave não foi lida pelo ssh-keygen)
  fp=$(ssh-keygen -l -f "$T/k.pub" 2>/dev/null | awk '{print $2}')
  [[ "$fp" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || { cleanup_t; nope "ssh-keygen nao leu a chave"; }
  want=$(printf '%s\n' "$keys" | awk '{print $1" "$2}')
  # getent: rc 0 existe · 2 não existe · outro rc = não consegui saber (nada é criado)
  getent passwd "$user" >/dev/null 2>&1; rc=$?
  case $rc in 0) existing=1 ;; 2) existing=0 ;; *) cleanup_t; cant "getent passwd rc=$rc" ;; esac
  if [ $existing = 1 ]; then
    H=$(getent passwd "$user" | awk -F: '{print $6}')
    AK="$H/.ssh/authorized_keys"
    # sem arquivo → instala; arquivo vazio/só comentários ou com OUTRA chave → recusa sem --replace (fail-closed: trocar a chave do admin é decisão explícita); ilegível → nao-consegui
    if [ -e "$AK" ]; then
      have=$(awk '!/^[[:space:]]*(#|$)/{print $1" "$2}' "$AK") || { cleanup_t; cant "leitura de $AK"; }
      [ "$have" = "$want" ] || [ "$replace" = 1 ] || { cleanup_t; nope "$AK ja tem outra chave (--replace para trocar)"; }
    fi
  fi
  # ── daqui em diante muda o nó
  # state anterior, lido ANTES de mexer na chave. vazio → sem admin gravado: marco novo; falhou/ilegível → campos vazios: marco novo e state invalidado (o mais exigente: a prova tem de ser posterior)
  old_user=""; old_fp=""; old_epoch=""
  if [ -e "$STATE/admin" ]; then
    old_user=$(awk -F= '$1=="user"{print $2}' "$STATE/admin" 2>/dev/null)
    old_fp=$(awk -F= '$1=="fp"{print $2}' "$STATE/admin" 2>/dev/null)
    old_epoch=$(awk -F= '$1=="epoch"{print $2}' "$STATE/admin" 2>/dev/null)
  fi
  # o state diz o que o admin DECIDIU; o authorized_keys é o que o sshd ACEITA. Se a chave vai mudar, o state antigo deixa de valer ANTES do authorized_keys mudar: uma falha daqui até o state novo (visudo, sudoers, escrita)
  # não pode deixar "fp=K1, login provado" apontando para um nó que já aceita a K2. Sem state, o rootcut recusa; remover falhou → 98 antes de tocar na chave
  if [ -e "$STATE/admin" ] && { [ "$old_user" != "$user" ] || [ "$old_fp" != "$fp" ]; }; then rm -f "$STATE/admin" || { cleanup_t; die state-invalida; }; fi
  if [ $existing = 0 ]; then useradd -m -s /bin/bash "$user" || { cleanup_t; die useradd; }; fi
  usermod -aG sudo "$user" || { cleanup_t; die grupo-sudo; }
  passwd -l "$user" >/dev/null 2>&1 || { cleanup_t; die passwd-l; }
  # vazio/falhou → home que não é caminho absoluto de um usuário comum: não escreve chave em lugar nenhum
  H=$(getent passwd "$user" | awk -F: '{print $6}')
  case "$H" in /|/root|"") cleanup_t; die "home-invalido:${H:-vazio}" ;; /*) ;; *) cleanup_t; die "home-invalido:$H" ;; esac
  AK="$H/.ssh/authorized_keys"
  mkdir -p "$H/.ssh" && chmod 700 "$H/.ssh" && chown "$user:$user" "$H/.ssh" || { cleanup_t; die ssh-dir; }
  printf '%s\n' "$keys" > "$AK.new" && chmod 600 "$AK.new" && chown "$user:$user" "$AK.new" && mv -f "$AK.new" "$AK" || { cleanup_t; die authorized_keys; }
  # o arquivo de sudoers só vale se o visudo aprovar; o nome com ponto é IGNORADO pelo sudo enquanto é temporário (um sudoers quebrado tiraria o sudo de todos)
  SF="$ETC/sudoers.d/90-gt-admin-$user"
  mkdir -p "$ETC/sudoers.d" || { cleanup_t; die sudoers-dir; }
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$SF.tmp" && chmod 0440 "$SF.tmp" || { cleanup_t; die sudoers-tmp; }
  visudo -cf "$SF.tmp" >/dev/null 2>&1 || { rm -f "$SF.tmp"; cleanup_t; die visudo; }
  mv -f "$SF.tmp" "$SF" || { cleanup_t; die sudoers-mv; }
  # a hora da instalação é o marco da prova do rootcut; MESMO usuário com a MESMA chave já gravada mantém a hora (a prova antiga continua valendo); qualquer outra combinação, ou marco ilegível → hora nova
  epoch=$(date +%s)
  if [ "$old_user" = "$user" ] && [ "$old_fp" = "$fp" ] && [[ "$old_epoch" =~ ^[0-9]+$ ]]; then epoch=$old_epoch; fi
  printf 'user=%s\nfp=%s\nepoch=%s\n' "$user" "$fp" "$epoch" > "$STATE/admin.new" && mv -f "$STATE/admin.new" "$STATE/admin" || { cleanup_t; die state; }
  cleanup_t
  note "admin $user fp=$fp"
  say "ok user=$user fp=$fp"
  say "PROXIMO: numa 2a sessao NOVA, entre como $user com a chave privada e rode 'sudo -n true'. O rootcut so aceita depois de ver esse login no journal. NAO feche a sessao de root."
  exit 0
}

cmd_fail2ban() {
  PHASE=fail2ban
  local ign="" J a ip got i
  local -a arr
  while [ $# -gt 0 ]; do
    case "$1" in --ignoreip) need_val $# "$1"; ign=$2; shift 2 ;; *) nope "argumento desconhecido: $1" ;; esac
  done
  need_root
  valid_srcs "$ign" || nope "--ignoreip obrigatorio e valido (o IP do mini): sem ele um ban corta o tunel e o espelho"
  # vazio → binário ausente: instala; falhou → 98 ANTES de escrever qualquer config
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1 || die apt-install
    command -v fail2ban-client >/dev/null 2>&1 || die apt-sem-binario
  fi
  J="$ETC/fail2ban/jail.d/gt-sshd.local"
  mkdir -p "$ETC/fail2ban/jail.d" || die jail-dir
  # vazio → sem config anterior: nada a guardar; falhou → 98 ANTES de sobrescrever (sem o backup o undo apagaria a config antiga em vez de restaurá-la)
  if [ -e "$J" ]; then cp -p "$J" "$J.prev" || die jail-backup; fi
  printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 %s\n\n[sshd]\nenabled = true\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' "${ign//,/ }" > "$J.new" && mv -f "$J.new" "$J" || die jail-escrita
  undo_f2b() { if [ -e "$J.prev" ]; then mv -f "$J.prev" "$J"; else rm -f "$J"; fi; systemctl stop fail2ban >/dev/null 2>&1; }
  fail2ban-client -t >/dev/null 2>&1 || { undo_f2b; die "config-test (fail2ban parado, drop-in removido)"; }
  systemctl enable fail2ban >/dev/null 2>&1 || { undo_f2b; die "enable (fail2ban parado, drop-in removido)"; }
  systemctl restart fail2ban >/dev/null 2>&1 || { undo_f2b; die "restart (fail2ban parado, drop-in removido)"; }
  # o servidor leva alguns segundos para abrir o socket: espera pela jail; sem resposta no prazo → desfaz (nunca "ativo por suposição")
  i=0; until fail2ban-client status sshd >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt "$WAIT_TRIES" ] || { undo_f2b; die "jail-sshd-sem-resposta (fail2ban parado, drop-in removido)"; }; sleep 1; done
  # vazio/falhou → sem lista de ignoreip: o jail NÃO está protegendo o mini → para o fail2ban (estado inerte) e diz
  got=$(fail2ban-client get sshd ignoreip 2>/dev/null) || { undo_f2b; die "ignoreip-ilegivel (fail2ban parado)"; }
  IFS=, read -r -a arr <<< "$ign"
  # o IP tem de ser um TOKEN da lista (substring enganaria: 198.51.100.7 "está" em 198.51.100.77). vazio/falhou → sem match → desfaz
  for a in "${arr[@]}"; do
    ip=${a%%/*}
    printf '%s\n' "$got" | awk -v ip="$ip" 'BEGIN{ip=tolower(ip)} { for (i=1;i<=NF;i++) { t=tolower($i); sub(/\/.*/,"",t); if (t==ip) f=1 } } END{exit f?0:1}' || { undo_f2b; die "ignoreip-ausente:$ip (fail2ban parado)"; }
  done
  rm -f "$J.prev"
  note "fail2ban ativo ignoreip=$ign"
  say "ok jail sshd ativa; ignoreip=$ign"
  exit 0
}

cmd_ufw() {
  PHASE=ufw
  local from="" st rc added s
  local -a arr
  while [ $# -gt 0 ]; do
    case "$1" in --ssh-from) need_val $# "$1"; from=$2; shift 2 ;; *) nope "argumento desconhecido: $1" ;; esac
  done
  need_root
  [ -n "$from" ] || nope "--ssh-from obrigatorio: 'any' ou IP/CIDR,... (any = qualquer origem, protegido por fail2ban; a lista so serve com IP do mini PROVADO fixo)"
  [ "$from" = any ] || valid_srcs "$from" || nope "--ssh-from invalido"
  command -v ufw >/dev/null 2>&1 || cant "ufw ausente"
  command -v systemd-run >/dev/null 2>&1 || cant "systemd-run ausente"
  ufw_active; rc=$?
  case $rc in 0|1) ;; *) cant "ufw status ilegivel" ;; esac
  # a(s) regra(s) da 22 entram ANTES de qualquer mudança de política: com o ufw já ativo, política deny sem a 22 cortaria as conexões novas
  if [ "$from" = any ]; then
    ufw allow 22/tcp >/dev/null 2>&1 || die allow-22
  else
    IFS=, read -r -a arr <<< "$from"
    for s in "${arr[@]}"; do ufw allow from "$s" to any port 22 proto tcp >/dev/null 2>&1 || die "allow-22-de:$s"; done
  fi
  # a regra da 22 tem de estar na lista ANTES do enable; vazio/ilegível → NÃO liga (ligar sem a 22 é o corte do servidor)
  added=$(ufw show added 2>/dev/null) || die show-added
  if [ "$from" = any ]; then
    case "$added" in *"allow 22/tcp"*) ;; *) die regra-22-ausente ;; esac
  else
    for s in "${arr[@]}"; do case "$added" in *"$s"*) ;; *) die "regra-22-ausente:$s" ;; esac; done
  fi
  ufw default deny incoming >/dev/null 2>&1 || die default-deny
  ufw default allow outgoing >/dev/null 2>&1 || die default-allow
  # ufw já ativo: não há enable nem rede, a política deny/allow acabou de valer NA HORA — sem timer de reversão. Diz isso claro e manda conferir
  if [ $rc = 0 ]; then say "ok ufw ja estava ativo: regras da 22 garantidas e politica deny incoming APLICADA na hora (sem enable, SEM rede de seguranca). Confira 'ufw status verbose' e prove uma conexao ssh NOVA"; exit 0; fi
  # sem rede de segurança armada, NÃO liga: se a regra estiver errada, o timer desliga o ufw sozinho em 10 min
  systemctl stop gt-ufw-revert.timer >/dev/null 2>&1
  systemd-run --quiet --unit=gt-ufw-revert --on-active=10min /usr/sbin/ufw disable >/dev/null 2>&1 || die rede-de-seguranca
  systemctl is-active gt-ufw-revert.timer >/dev/null 2>&1 || die rede-nao-armada
  ufw --force enable >/dev/null 2>&1 || die enable
  ufw_active || die "ufw-nao-ficou-ativo (a rede de seguranca desliga em 10 min)"
  note "ufw ativo from=$from rede=10min"
  say "ok ufw ATIVO (22 liberada de: $from). REDE DE SEGURANCA armada: em 10 min o ufw desliga sozinho."
  say "PROVE agora uma conexao ssh NOVA (as abertas sobrevivem ao enable; o erro so aparece na proxima) e rode: $0 confirm ufw"
  exit 0
}

cmd_rootcut() {
  PHASE=rootcut
  local nota1="" user fp epoch j n s D eff H AK have inst instfp
  while [ $# -gt 0 ]; do
    case "$1" in --sem-trava1) need_val $# "$1"; nota1=$2; shift 2 ;; *) nope "argumento desconhecido: $1" ;; esac
  done
  need_root
  # (1) admin gravado — vazio → sem admin: recusa; ilegível/campo faltando → nao-consegui
  [ -e "$STATE/admin" ] || nope "sem admin gravado: rode 'admin' primeiro"
  user=$(awk -F= '$1=="user"{print $2}' "$STATE/admin" 2>/dev/null) || cant "leitura do state"
  fp=$(awk -F= '$1=="fp"{print $2}' "$STATE/admin" 2>/dev/null) || cant "leitura do state"
  epoch=$(awk -F= '$1=="epoch"{print $2}' "$STATE/admin" 2>/dev/null) || cant "leitura do state"
  [[ "$user" =~ ^[a-z][a-z0-9_-]{2,31}$ && "$fp" =~ ^SHA256:[A-Za-z0-9+/]{43}$ && "$epoch" =~ ^[0-9]+$ ]] || cant "state do admin incompleto"
  # (1b) a chave que o sshd ACEITA é a gravada. O state diz o que o admin decidiu; o authorized_keys é o que vale no login. Lê o arquivo de verdade e compara o fingerprint com o do state
  # getent: rc 0 existe · rc 2 não existe (recusa) · outro rc = falhou/ilegível → nao-consegui. Home que não é caminho absoluto de usuário comum → nao-consegui (não leio em lugar nenhum)
  getent passwd "$user" >/dev/null 2>&1; n=$?
  case $n in 0) ;; 2) nope "usuario admin $user nao existe: rode 'admin' de novo" ;; *) cant "getent passwd $user rc=$n" ;; esac
  H=$(getent passwd "$user" | awk -F: '{print $6}')
  case "$H" in /|/root|"") cant "home do admin invalido: ${H:-vazio}" ;; /*) ;; *) cant "home do admin invalido: $H" ;; esac
  AK="$H/.ssh/authorized_keys"
  # vazio → sem arquivo, ou só comentários: recusa (o admin não tem chave instalada); falhou/ilegível → nao-consegui
  [ -e "$AK" ] || nope "$AK nao existe: o admin nao tem chave instalada. Rode 'admin --replace' e prove o login de novo"
  have=$(awk '!/^[[:space:]]*(#|$)/' "$AK") || cant "leitura de $AK"
  [ -n "$have" ] || nope "$AK sem chave: o admin nao tem chave instalada. Rode 'admin --replace' e prove o login de novo"
  [ "$(printf '%s\n' "$have" | awk 'END{print NR}')" = 1 ] || nope "$AK tem mais de uma chave: so a gravada pode entrar. Rode 'admin --replace' e prove o login de novo"
  inst=$(ssh-keygen -l -f "$AK" 2>/dev/null) || cant "ssh-keygen -l -f $AK"
  instfp=$(printf '%s\n' "$inst" | awk '{print $2}')
  [ "$instfp" = "$fp" ] || nope "chave instalada (${instfp:-?}) difere da gravada ($fp): rode 'admin --replace' e prove o login de novo"
  # (2) a trava 1 usa o root atual: o usuário `dados` existir é a prova de que ela foi aplicada; o override exige motivo e fica no log
  # getent: rc 0 existe · rc 2 não existe (vazio → sem `dados`: recusa, ou override com motivo) · qualquer outro rc = falhou/ilegível → nao-consegui (nunca vira "não existe")
  getent passwd dados >/dev/null 2>&1; n=$?
  case $n in
    0) ;;
    2) if [ -n "$nota1" ] && [ "${#nota1}" -ge 10 ]; then note "rootcut sem a trava 1: $nota1"; else nope "usuario 'dados' (trava 1) nao existe: aplique a ga-qg1dw5z.1 antes, ou --sem-trava1 \"motivo (>=10 letras)\""; fi ;;
    *) cant "getent passwd dados rc=$n" ;;
  esac
  # (3) ufw ativo
  ufw_active; case $? in 0) ;; 1) nope "ufw inativo: rode 'ufw' e 'confirm ufw' antes" ;; *) cant "ufw status ilegivel" ;; esac
  # (4) jail sshd de pé
  command -v fail2ban-client >/dev/null 2>&1 || nope "fail2ban ausente: rode 'fail2ban' antes"
  fail2ban-client status sshd >/dev/null 2>&1 || nope "jail sshd do fail2ban nao responde: rode 'fail2ban' antes"
  # (5) login real do admin com a chave gravada, DEPOIS da instalação. vazio → nenhuma linha: recusa; falhou/ilegível → nao-consegui
  j=$(journalctl -u ssh -u ssh.socket --since "@$epoch" --no-pager -o cat 2>/dev/null) || cant "journalctl"
  n=$(printf '%s\n' "$j" | awk -v u="$user" -v f="$fp" 'index($0,"Accepted publickey for " u " from ") && index($0,f) {c++} END{print c+0}')
  [ "$n" -ge 1 ] || nope "sem prova: nenhum login do admin $user com a chave $fp no journal desde a instalacao. Entre por uma 2a sessao NOVA e rode de novo"
  # vazio → saída sem `NOPASSWD: ALL`: recusa; falhou/ilegível → nao-consegui (nunca vira "sudo ok")
  s=$(sudo -n -l -U "$user" 2>/dev/null) || cant "sudo -l -U $user"
  case "$s" in *"NOPASSWD: ALL"*) ;; *) nope "sudo do admin $user nao esta valido (esperado NOPASSWD: ALL)" ;; esac
  # ── tudo provado: age. O drop-in vale porque o Include fica no TOPO do sshd_config (conferido pelo sshd -T abaixo, não suposto)
  D="$ETC/ssh/sshd_config.d/10-gt-lockdown.conf"
  mkdir -p "$ETC/ssh/sshd_config.d" || die dropin-dir
  printf '# ga-qg1dw5z.2: root sem login ssh. Desfazer: hetzner-ssh-lockdown.sh undo rootcut\nPermitRootLogin no\n' > "$D.new" && mv -f "$D.new" "$D" || die dropin-escrita
  sshd -t >/dev/null 2>&1 || { rm -f "$D"; die "sshd-t (drop-in removido)"; }
  eff=$(sshd_root_eff)
  [ "$eff" = no ] || { rm -f "$D"; die "efetivo=${eff:-?} (drop-in removido; o Include nao esta no topo?)"; }
  systemctl stop gt-rootcut-revert.timer >/dev/null 2>&1
  systemd-run --quiet --unit=gt-rootcut-revert --on-active=10min /bin/sh -c "rm -f $D && systemctl reload ssh" >/dev/null 2>&1 || { rm -f "$D"; die "rede-de-seguranca (drop-in removido)"; }
  systemctl is-active gt-rootcut-revert.timer >/dev/null 2>&1 || { rm -f "$D"; die "rede-nao-armada (drop-in removido)"; }
  systemctl reload ssh >/dev/null 2>&1 || { rm -f "$D"; die "reload (drop-in removido)"; }
  note "rootcut aplicado admin=$user rede=10min"
  say "ok PermitRootLogin no (efetivo). REDE DE SEGURANCA: em 10 min o root volta sozinho se nao confirmar."
  say "NAO feche esta sessao de root. PROVE: (mini) 'ssh root@<no>' recusa; 'ssh $user@<no> sudo -n true' entra; tunel 2293 e workers vivos. Depois: $0 confirm rootcut"
  exit 0
}

cmd_confirm() {
  PHASE=confirm
  local what=${1:-} eff
  need_root
  case "$what" in
    ufw)
      # o timer pode já ter disparado (ufw desligado): então não há o que confirmar
      ufw_active; case $? in 0) ;; 1) nope "o ufw esta desligado (a rede de seguranca disparou ou foi desligado): nada a confirmar" ;; *) cant "ufw status ilegivel" ;; esac
      systemctl stop gt-ufw-revert.timer >/dev/null 2>&1
      systemctl is-active gt-ufw-revert.timer >/dev/null 2>&1 && die "timer-ainda-armado"
      note "confirm ufw"; say "ok ufw confirmado; rede de seguranca cancelada" ;;
    rootcut)
      # vazio/falhou → sshd -T sem resposta: nao-consegui (a rede continua armada, nada é cancelado); resposta diferente de "no" (o timer já reabriu o root, ou o drop-in sumiu): nada a confirmar
      eff=$(sshd_root_eff)
      [ -n "$eff" ] || cant "sshd -T ilegivel: nao confirmo as cegas (a rede de seguranca continua armada)"
      [ "$eff" = no ] || nope "permitrootlogin efetivo=${eff:-?}: o root ja voltou (rede disparou) ou o rootcut nao esta aplicado"
      systemctl stop gt-rootcut-revert.timer >/dev/null 2>&1
      systemctl is-active gt-rootcut-revert.timer >/dev/null 2>&1 && die "timer-ainda-armado"
      note "confirm rootcut"; say "ok rootcut confirmado; rede de seguranca cancelada" ;;
    *) nope "uso: confirm ufw|rootcut" ;;
  esac
  exit 0
}

cmd_undo() {
  PHASE=undo
  need_root
  case "${1:-}" in
    ufw) ufw disable >/dev/null 2>&1 || die ufw-disable; systemctl stop gt-ufw-revert.timer >/dev/null 2>&1; note "undo ufw"; say "ok ufw desligado" ;;
    rootcut) rm -f "$ETC/ssh/sshd_config.d/10-gt-lockdown.conf" || die rm-dropin; systemctl reload ssh >/dev/null 2>&1 || die reload; systemctl stop gt-rootcut-revert.timer >/dev/null 2>&1; note "undo rootcut"; say "ok root volta a entrar por chave" ;;
    *) nope "uso: undo ufw|rootcut" ;;
  esac
  exit 0
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  status) cmd_status ;;
  origins) cmd_origins ;;
  admin) cmd_admin "$@" ;;
  fail2ban) cmd_fail2ban "$@" ;;
  ufw) cmd_ufw "$@" ;;
  rootcut) cmd_rootcut "$@" ;;
  confirm) cmd_confirm "$@" ;;
  undo) cmd_undo "$@" ;;
  *) echo "uso: $0 status|origins|admin|fail2ban|ufw|rootcut|confirm|undo   (ver o cabecalho)" >&2; exit 2 ;;
esac
