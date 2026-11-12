#!/bin/bash
# hetzner-dados-run.sh — roda UM entrypoint do build como o usuário `dados`, sem rede, com o dado em tmpfs, e apaga o dado ao fim (ga-qg1dw5z.1). Instalado por ROOT como /usr/local/sbin/gt-dados-run.
#
# ## Contents
#   Por quê · Uso · O que o build enxerga · Códigos de saída
#
# POR QUÊ: agentes (runner) e dado pessoal moravam no MESMO usuário: um pacote npm/PyPI envenenado ou uma injeção de prompt por página raspada leria o cadastro. Aqui o dado só existe
#   no staging do usuário `dados` (que o runner não lê), só enquanto este wrapper roda, e o código que roda como `dados` é uma árvore de ROOT que o runner não edita.
# USO: sudo -n /usr/local/sbin/gt-dados-run <entrypoint>   (sudoers: UMA linha por entrypoint, sem curinga; o nome tem de estar também em /etc/gt-dados/entrypoints)
# O QUE O BUILD ENXERGA: netns novo sem saída (mesmo padrão do gt-netns-run: `lo` aceito, o resto rejeitado COM contador), uid/gid `dados` sem grupos extras nem capacidades (setpriv --no-new-privs),
#   ambiente LIMPO (env -i), GT_DADOS_STAGE=/srv/gtdados (tmpfs dedicado: entrada em in/, resultado em out/), prazo de 2 h. Ao fim apaga in/ (o dado), mata o que sobrou no netns e confere que in/ ficou vazio.
#   O resultado em out/ sai SÓ pelo canal do mini (gt-dados-ingest `get`), nunca por diretório legível ao runner.
#   in/ e out/ são nomes do build: link simbólico ou arquivo no lugar deles → `recusado:stage-dirs` (98) antes de rodar, e, se o build os trocar durante a rodada, `GTD-WIPE: falhou` (99). Root nunca dá chown/chmod num caminho que o build escolhe.
# CÓDIGOS: o do entrypoint · 64 uso/fora da lista · 98 recusei antes de rodar (`GTD-RUN: recusado:<motivo>`: nada rodou) · 99 o entrypoint terminou mas in/ NÃO ficou vazio ou não é mais um diretório (`GTD-WIPE: falhou`; a varredura diária tenta de novo e apaga o link)
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
DU=dados; STAGE=/srv/gtdados; LIST=/etc/gt-dados/entrypoints; APP=/opt/gt-dados/app/bin; LOCK=/run/gt-dados-run.lock; SWAPS=/proc/swaps; MAXSECS=7200
usage() { echo "GTD-RUN: recusado:$1" >&2; exit 64; }
[ $# -eq 1 ] && [ "${SUDO_UID:-0}" -gt 0 ] 2>/dev/null || { echo "uso: sudo $0 <entrypoint>" >&2; exit 64; }
NAME=$1
case $NAME in ''|-*|.*|*[!a-z0-9_.-]*) usage nome-invalido ;; esac
# vazio/falhou (lista ausente ou ilegível) → recusa: só a linha EXATA do nome libera, nunca "sem lista = livre"
grep -Fx -- "$NAME" "$LIST" > /dev/null 2>&1 || usage fora-da-lista
NS="gtd$$"; CHILD=""; CANCEL=""
# vazio → in/ sem nada; falhou (in/ sumiu, virou link simbólico ou arquivo — o build manda nesse nome —, find com erro) → rc 1: nunca vira "limpo". `find` não entra num link dado como ponto de partida, então sem esta guarda um in/ trocado por link daria "vazio" sem apagar nada
wipe_in() { local left; { [ -d "$STAGE/in" ] && [ ! -L "$STAGE/in" ]; } || return 1; find "$STAGE/in" -mindepth 1 -delete 2> /dev/null; left=$(find "$STAGE/in" -mindepth 1 -print -quit 2> /dev/null) || return 1; [ -z "$left" ]; }
cleanup() {
  # o netns só some quando o último processo dentro dele sai: mata o que sobrou (todo processo do build nasce dentro dele, setsid não escapa) ANTES de apagar in/, para ninguém recriar arquivo
  # vazio → ninguém sobrou; falhou/ilegível → segue: o `del` e a verificação de in/ abaixo dizem o resto
  ip netns pids "$NS" 2> /dev/null | xargs -r kill -9 2> /dev/null
  ip netns del "$NS" 2> /dev/null; find "/etc/netns/$NS" -mindepth 1 -delete 2> /dev/null; rmdir "/etc/netns/$NS" 2> /dev/null; return 0
}
fail() { echo "GTD-RUN: recusado:$1" >&2; cleanup; exit 98; }
trap 'cleanup' EXIT
trap 'CANCEL=1; [ -z "$CHILD" ] || kill -TERM "$CHILD" 2> /dev/null' TERM INT HUP
# o entrypoint e a pasta dele são de root e ninguém mais escreve: vazio/falhou (find sem saída) → recusa
[ -n "$(find "$APP/$NAME" -maxdepth 0 -type f -user root ! -perm -020 ! -perm -002 -perm -100 2> /dev/null)" ] && [ -n "$(find "$APP" -maxdepth 0 -user root ! -perm -020 ! -perm -002 2> /dev/null)" ] || fail entrypoint-nao-e-de-root
DUID=$(id -u "$DU" 2> /dev/null); DGID=$(id -g "$DU" 2> /dev/null)
case "$DUID$DGID" in ''|*[!0-9]*) fail usuario-dados ;; esac
[ "$DUID" -gt 0 ] || fail usuario-dados
# tmpfs de verdade e montagem PRÓPRIA: vazio/falhou (findmnt ausente, diretório solto no disco) → recusa; o dado nunca vai a bloco de disco por engano
[ "$(findmnt -no FSTYPE --target "$STAGE" 2> /dev/null)" = tmpfs ] && mountpoint -q "$STAGE" || fail stage-nao-e-tmpfs
# swap ligada deixaria a RAM do tmpfs ir a disco; /proc/swaps ilegível também recusa (só o cabeçalho sozinho, 1 linha, libera)
SW=$({ wc -l < "$SWAPS"; } 2> /dev/null | tr -d ' ')
[ "$SW" = 1 ] || fail swap-ligada-ou-ilegivel
# o lock é só de ROOT (0600): com 0644 qualquer usuário local (o runner!) faria `flock -x` nele e todo build recusaria `ocupado` (revisão de segurança, 12/11). Falhou em criar/ajustar o modo → recusa
( umask 077; : >> "$LOCK" ) 2> /dev/null && chmod 0600 "$LOCK" 2> /dev/null || fail lock-modo
exec 9> "$LOCK" && flock -n 9 || fail ocupado
# in/ e out/ são nomes que o BUILD (dados) controla: ele pode trocá-los por link simbólico, e `install -d -o -g -m` como ROOT SEGUE o link e dá chown/chmod no ALVO (revisão do gate, 12/11: dados chegava a root por /usr/local/sbin). Aqui root NUNCA segue nome do dados:
# existe (inclusive link solto) e não é diretório de verdade, ou o find falhou → recusa stage-dirs, nada é tocado; não existe → mkdir (não segue nada) + chown -h (não segue link). Só não existir cria.
for d in in out; do
  if [ -e "$STAGE/$d" ] || [ -L "$STAGE/$d" ]; then [ -n "$(find "$STAGE/$d" -maxdepth 0 -type d 2> /dev/null)" ] || fail stage-dirs
  else mkdir -m 0700 "$STAGE/$d" && chown -h "$DU:$DU" "$STAGE/$d" || fail stage-dirs; fi
done
ip netns add "$NS" || fail netns-add
ip -n "$NS" link set lo up || fail lo
ip -n "$NS" link add gtn0 type dummy && ip -n "$NS" addr add 192.0.2.2/24 dev gtn0 && ip -n "$NS" link set gtn0 up \
  && ip -n "$NS" route add default via 192.0.2.1 dev gtn0 || fail gtn0
mkdir -p "/etc/netns/$NS" && echo "nameserver 192.0.2.1" > "/etc/netns/$NS/resolv.conf" || fail resolv
ip netns exec "$NS" nft -f - << 'EOF' || fail nft
table inet gtn {
  counter egress { }
  chain out { type filter hook output priority 0; policy drop; oifname "lo" accept; counter name egress reject; }
  chain in { type filter hook input priority 0; policy drop; iifname "lo" accept; }
}
EOF
# vazio/falhou/ilegível (a regra `reject` não aparece) → recusa, o entrypoint NÃO roda: isolamento não confirmado nunca vira "isolado"
ip netns exec "$NS" nft list chain inet gtn out 2> /dev/null | grep -q 'reject' || fail nft-regra
[ -z "$CANCEL" ] || fail cancelado
echo "GTD-RUN: ok ns=$NS entrypoint=$NAME" >&2
ip netns exec "$NS" timeout -k 10 "$MAXSECS" setpriv --reuid="$DUID" --regid="$DGID" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
  /usr/bin/env -i HOME="/home/$DU" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 GT_DADOS_STAGE="$STAGE" "$APP/$NAME" &
CHILD=$!
[ -z "$CANCEL" ] || kill -TERM "$CHILD" 2> /dev/null
wait "$CHILD"; rc=$?
while kill -0 "$CHILD" 2> /dev/null; do wait "$CHILD"; rc=$?; done
# contador em "packets 0" → attempts=0; saída vazia/ilegível → "?" (nunca vira 0)
n=$(ip netns exec "$NS" nft list counter inet gtn egress 2> /dev/null | sed -n 's/.*packets \([0-9][0-9]*\).*/\1/p' | head -n 1)
echo "GTD-EGRESS: attempts=${n:-?}" >&2
cleanup
# apagar o dado é o trabalho; in/ que não ficou vazio (ou não consegui ler) NUNCA vira "limpo": 99 vence o rc do entrypoint
if wipe_in; then echo "GTD-WIPE: ok" >&2; else echo "GTD-WIPE: falhou (in/ não ficou vazio ou ilegível; a varredura diária tenta de novo)" >&2; exit 99; fi
exit "$rc"
