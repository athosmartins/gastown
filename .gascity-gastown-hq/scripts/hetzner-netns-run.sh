#!/bin/bash
# hetzner-netns-run.sh — roda um comando SEM rede de saída no nó Linux de testes (ga-9p6pte). Instalado por ROOT como /usr/local/sbin/gt-netns-run.
#
# ## Contents
#   Por quê · Uso · O que o comando enxerga · Códigos de saída · Instalação
#
# POR QUÊ: em 04/10 um teste de branch antiga mandou um e-mail de verdade. O nó não tem root para o `runner`, o AppArmor barra userns sem
#   privilégio e `systemd-run --user -p PrivateNetwork=yes` volta rc 0 SEM isolar (medido: eth0 presente, 1.1.1.1:53 conectou). Por isso o
#   isolamento é deste helper, que roda como root via sudo, e quem o usa PROVA o resultado com um canário (hetzner-iso-run.sh) em vez de confiar no rc.
# USO: sudo -n /usr/local/sbin/gt-netns-run -- <comando> [args]   (o comando pode começar com VAR=valor: quem lê é o `env`)
# O QUE O COMANDO ENXERGA: um netns novo por execução com `lo` e uma interface `gtn0` (dummy) que é a rota padrão. A tabela nft do netns tem
#   `lo` aceito e TODO o resto rejeitado COM contador: tentativa de saída falha na hora (ECONNREFUSED, não pendura 130 s de SYN) e vira número.
#   DNS: o resolv.conf do netns aponta para 192.0.2.1 (cai na mesma regra), então "DNS negado" é a regra, não um serviço fora do ar.
#   O comando roda com o uid/gid de quem chamou o sudo, SEM capacidades (setpriv), e com ambiente LIMPO (env -i): sem segredo por construção.
#   Ao fim, a linha `GTN-EGRESS: attempts=N` (stderr) diz quantas tentativas de saída o nft barrou; `attempts=?` = não consegui ler o contador.
#   O `log` do nft NÃO é usado: fora do netns inicial o kernel não loga (nf_log_all_netns=0), então o contador é a evidência.
# CÓDIGOS: o do comando · 98 não montei o isolamento (o comando NÃO rodou; `GTN-ISO: setup-falhou:<passo>`) · 64 uso/quem chamou
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "${1:-}" = -- ] && shift
[ $# -gt 0 ] && [ "${SUDO_UID:-0}" -gt 0 ] 2>/dev/null && [ "${SUDO_GID:-0}" -gt 0 ] 2>/dev/null || { echo "hetzner-netns-run: uso: sudo $0 -- <comando>" >&2; exit 64; }
NS="gtn$$"
CHILD=""
cleanup() {
  # o netns só some quando o último processo dentro dele sai: mata o que sobrou antes (o comando já rodou como o chamador, nunca como root)
  # vazio → ninguém sobrou, nada a matar; falhou/ilegível → segue para o `del` (se o netns ficar, o próximo sudo cria outro nome: não trava nem isola menos)
  ip netns pids "$NS" 2>/dev/null | xargs -r kill -9 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  find "/etc/netns/$NS" -mindepth 1 -delete 2>/dev/null; rmdir "/etc/netns/$NS" 2>/dev/null; return 0
}
fail() { echo "GTN-ISO: setup-falhou:$1" >&2; cleanup; exit 98; }
trap 'cleanup' EXIT
CANCEL=""
# TERM/INT/HUP: com o comando já rodando, repassa a ele; ainda na montagem (CHILD vazio) só marca o cancelamento, e o comando NÃO sai (conferido logo antes de lançá-lo)
trap 'CANCEL=1; [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null' TERM INT HUP
ip netns add "$NS" || fail netns-add
ip -n "$NS" link set lo up || fail lo
ip -n "$NS" link add gtn0 type dummy && ip -n "$NS" addr add 192.0.2.2/24 dev gtn0 && ip -n "$NS" link set gtn0 up \
  && ip -n "$NS" route add default via 192.0.2.1 dev gtn0 || fail gtn0
mkdir -p "/etc/netns/$NS" && echo "nameserver 192.0.2.1" > "/etc/netns/$NS/resolv.conf" || fail resolv
ip netns exec "$NS" nft -f - <<'EOF' || fail nft
table inet gtn {
  counter egress { }
  chain out { type filter hook output priority 0; policy drop; oifname "lo" accept; counter name egress reject; }
  chain in { type filter hook input priority 0; policy drop; iifname "lo" accept; }
}
EOF
# vazio/falhou/ilegível (a regra `reject` não aparece na listagem) → 98, o comando NÃO roda: isolamento não confirmado nunca vira "isolado"
ip netns exec "$NS" nft list chain inet gtn out 2>/dev/null | grep -q 'reject' || fail nft-regra
# vazio/falhou (o chamador não existe no passwd) → 98, o comando NÃO roda: sem HOME o ambiente limpo sairia diferente do testado
HOME_U=$(getent passwd "$SUDO_UID" | cut -d: -f6); [ -n "$HOME_U" ] || fail passwd
# cancelado durante a montagem (o sinal só é tratado entre os comandos acima) → 98, o comando NÃO roda
[ -z "$CANCEL" ] || fail cancelado
echo "GTN-ISO: ok ns=$NS uid=$SUDO_UID" >&2
ip netns exec "$NS" setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
  /usr/bin/env -i HOME="$HOME_U" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 "$@" &
CHILD=$!
# o sinal pode ter chegado entre o lançamento e a atribuição de CHILD: repassa agora
[ -z "$CANCEL" ] || kill -TERM "$CHILD" 2>/dev/null
wait "$CHILD"; rc=$?
# a espera pode ter sido interrompida por um sinal (o trap): espera de novo para ter o rc DO comando
while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD"; rc=$?; done
# contador em "packets 0" → attempts=0 (nenhuma tentativa); saída vazia/ilegível → "?" (nunca vira 0)
n=$(ip netns exec "$NS" nft list counter inet gtn egress 2>/dev/null | sed -n 's/.*packets \([0-9][0-9]*\).*/\1/p' | head -n 1)
echo "GTN-EGRESS: attempts=${n:-?}" >&2
exit "$rc"
