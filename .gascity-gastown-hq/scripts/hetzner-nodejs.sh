#!/usr/bin/env bash
# hetzner-nodejs.sh — Node.js no nó Linux (Hetzner) em nível de USUÁRIO (ga-2hd02v.4.9). Roda no MINI, fala com o nó por ssh e só escreve em ~/.local do usuário do nó. Doc: docs/runbooks/hetzner-nodejs.md
#
# Contents
#   Para que serve · Subcomandos · Códigos de saída · Por que é seguro · Limites
#
# PARA QUE SERVE: os testes do property_scrapers que chamam `node` (shutil.which("node")) reprovavam no nó só porque o binário não existe: 242 dos 245 problemas da rodada vinham disso (scripts/hetzner-mac-only.ps.txt).
#   Decisão do Mayor (ga-2hd02v.4, 21/10 02:40Z): instalar o Node no nó SEM sudo e SEM mexer no sistema, só para os testes do PS. O nó é aarch64 (Ubuntu 24.04): o tarball é linux-arm64, não x64.
# SUBCOMANDOS: check [--pin ARQ] · install [--pin ARQ]      (pin padrão: scripts/hetzner-nodejs.pin; HETZNER_NODEJS_PIN troca)
#   check    só LÊ o nó. Diz se o node do nó é exatamente o do pin.
#   install  baixa o tarball NO NÓ, confere o sha256 contra o hash do pin (que vem do mini, nunca de arquivo baixado pelo nó), extrai em ~/.local/node-v<V>-linux-arm64, roda o binário e só se ele disser v<V>
#            troca os symlinks ~/.local/node e ~/.local/bin/node. Já está igual ao pin = não baixa nada (rc 0). Só o `node` ganha link: npm/npx ficam dentro do diretório, sem entrar no PATH.
# CÓDIGOS: 0 igual ao pin / instalado · 1 check: ausente, quebrado ou outra versão · install: depois de instalar a conferência final LEU o nó e ele não está ok (se não conseguiu ler é rc 2) · 2 NÃO consegui saber (pin ilegível ou ambíguo, ssh caiu, saída que não reconheço; nunca vira "ausente")
#   3 o nó não é o que o pin cobre (SO/arquitetura) · 4 recusado (sha256 não confere, o binário diz outra versão, ARQUIVO COMUM no lugar de um dos links, diretório da versão que já existe e não é o node certo) · 5 download falhou · 64 uso errado (nunca 2, que é "não consegui saber")
#   Um symlink que já exista em ~/.local/node ou ~/.local/bin/node é tratado como nosso e é trocado (o nó não tinha nenhum em 21/10); só arquivo ou diretório comum é recusado.
# POR QUE É SEGURO: o estado antigo só muda nos dois `ln -sfn` do FIM do install; qualquer recusa antes deles deixa o nó como estava (o diretório novo da versão pode já existir, sem link apontando para ele). O pin é DADO (lido por grep, nunca `source`) e versão/hash passam por regex antes de ir ao ssh.
#   O diretório de cada versão é imutável: trocar de versão não apaga a anterior (desfazer = religar os links; receita no runbook). Não usa sudo, apt, npm install nem toca no python/venv do nó.
# LIMITES: duas instalações ao mesmo tempo não são serializadas (não há lock): a que chegar depois do `mv` da outra confere a versão do diretório e o reaproveita; numa corrida estrita dos dois `mv` o perdedor pode deixar
#   um diretório aninhado inofensivo dentro do diretório da versão (os links continuam certos). Rode um install por vez. A troca de link por `ln -sfn` não é uma transação
#   de duas peças: entre ~/.local/node e ~/.local/bin/node há alguns microssegundos em que o primeiro já mudou. Aceitável aqui: o nó só roda teste, e a troca só existe quando a versão do pin muda.
#   Selftest: scripts/hetzner-nodejs.selftest.sh (ssh, curl e uname trocados por stubs; o script remoto roda de verdade num HOME temporário).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH_BIN=${MBP_SSH:-ssh}; HOST=${HETZNER_NODE_HOST:-hetzner-teste}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
PIN=${HETZNER_NODEJS_PIN:-$HERE/hetzner-nodejs.pin}
RE_VER='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; RE_SHA='^[0-9a-f]{64}$'
say() { echo "NODEJS $*"; }
die() { local rc=$1; shift; say "$*"; exit "$rc"; }
usage() { echo "uso: hetzner-nodejs.sh check|install [--pin ARQUIVO]" >&2; exit 64; }

cmd=${1:-}; [ -n "$cmd" ] && shift
case "$cmd" in check|install) ;; *) usage ;; esac
while [ $# -gt 0 ]; do case "$1" in --pin) [ $# -ge 2 ] || usage; PIN=$2; shift 2 ;; *) usage ;; esac; done

# O pin é DADO: duas linhas KEY=valor, cada uma exatamente uma vez. Ausente, ilegível, repetida ou fora do formato = rc 2 (não sei qual versão), nunca uma versão padrão.
pin_get() { local n; n=$(grep -c -E "^$1=" "$PIN" 2>/dev/null) || n=0; [ "$n" = 1 ] || return 1; grep -E "^$1=" "$PIN" | sed -e "s/^$1=//"; }
[ -r "$PIN" ] || die 2 "NAO-CONSEGUI: pin ilegível ou ausente ($PIN)"
# vazio → pin_get devolve 1 (rc 2 abaixo); falhou/ilegível → idem: nunca cai numa versão padrão
V=$(pin_get NODE_VERSION) || die 2 "NAO-CONSEGUI: $PIN não tem NODE_VERSION exatamente uma vez"
SHA=$(pin_get NODE_SHA256_LINUX_ARM64) || die 2 "NAO-CONSEGUI: $PIN não tem NODE_SHA256_LINUX_ARM64 exatamente uma vez"
[[ "$V" =~ $RE_VER ]] || die 2 "NAO-CONSEGUI: NODE_VERSION fora do formato N.N.N ($V)"
[[ "$SHA" =~ $RE_SHA ]] || die 2 "NAO-CONSEGUI: NODE_SHA256_LINUX_ARM64 fora do formato (64 hex minúsculos)"

# Só LÊ. Imprime ARCH, NODE e a sentinela FIM; sem a sentinela quem chama trata como "não consegui ler".
remote_probe() { cat <<'EOF'
V=$1
# vazio/falhou → ~/.local ainda não existe ou não é atravessável (permissão): fica o literal e o `-e` abaixo falha igual (o check diz ausente e o install falha alto no mkdir); existindo, o caminho CANÔNICO, porque o readlink -f abaixo também resolve tudo e $HOME pode cruzar um symlink
H=$(cd "$HOME/.local" 2>/dev/null && pwd -P) || H=$HOME/.local
echo "ARCH $(uname -s) $(uname -m)"
n=$H/bin/node
if [ -L "$n" ] || [ -e "$n" ]; then
  real=$(readlink -f "$n" 2>/dev/null) || real=?
  ver=$("$n" --version 2>/dev/null | head -n 1); [ -n "$ver" ] || ver=ERRO
  case "$real" in "$H/node-v$V-linux-arm64/bin/node") loc=certo ;; *) loc=outro ;; esac
  echo "NODE $ver $loc"
else
  echo "NODE ausente"
fi
echo FIM
EOF
}

# Escreve só em ~/.local do usuário do nó. Códigos: 3 arquitetura · 4 recusado · 5 download · 6 outra falha. Os symlinks são a ÚLTIMA coisa que muda.
remote_install() { cat <<'EOF'
set -eu
V=$1; SHA=$2
H=$HOME/.local; AD=node-v$V-linux-arm64; D=$H/$AD
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || { echo "RECUSO arquitetura $(uname -s) $(uname -m)"; exit 3; }
mkdir -p "$H/bin"
for l in "$H/node" "$H/bin/node"; do
  if [ -e "$l" ] || [ -L "$l" ]; then [ -L "$l" ] || { echo "RECUSO $l existe e não é um symlink: não toco"; exit 4; }; fi
done
T=$(mktemp -d "$H/.nodejs-install.XXXXXX") || { echo "RECUSO sem diretório temporário"; exit 6; }
trap 'cd /; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 900 -o "$T/node.tar.xz" "https://nodejs.org/dist/v$V/$AD.tar.xz" || { echo "RECUSO download falhou"; exit 5; }
echo "STEP baixou $(wc -c < "$T/node.tar.xz" | tr -d ' ') bytes"
printf '%s  %s\n' "$SHA" "$T/node.tar.xz" | sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 não confere com o pin"; exit 4; }
echo "STEP sha256-ok"
tar -xJf "$T/node.tar.xz" -C "$T" || { echo "RECUSO tar não extraiu"; exit 6; }
[ -x "$T/$AD/bin/node" ] || { echo "RECUSO o tarball não tem $AD/bin/node"; exit 4; }
got=$("$T/$AD/bin/node" --version 2>/dev/null | head -n 1) || got=
[ "$got" = "v$V" ] || { echo "RECUSO o binário diz '${got:-nada}', o pin é v$V"; exit 4; }
echo "STEP binario-roda $got"
if [ -e "$D" ]; then
  [ "$("$D/bin/node" --version 2>/dev/null | head -n 1)" = "v$V" ] || { echo "RECUSO $D já existe e não é o node v$V: não mexo"; exit 4; }
  echo "STEP diretorio-ja-existia"
else
  mv "$T/$AD" "$D"
fi
ln -sfn "$AD" "$H/node"
ln -sfn "../node/bin/node" "$H/bin/node"
echo "STEP linkado"
echo FIM
EOF
}

# Pergunta ao nó (só leitura) e classifica em STATE: ok · ausente · diferente · quebrado · arquitetura · nao-consegui. Não imprime nem sai: quem chama decide o rc.
STATE=; DETAIL=
probe() {
  local out rc arch node ver loc
  # vazio → sem sentinela FIM = nao-consegui (nunca "ausente"); falhou/ilegível (ssh rc≠0) → idem
  out=$(remote_probe | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- "$V" 2>/dev/null); rc=$?
  if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'FIM'; then STATE=nao-consegui; DETAIL="ssh para $HOST caiu (rc $rc) ou a resposta veio incompleta"; return 0; fi
  arch=$(printf '%s\n' "$out" | grep -E '^ARCH ' | head -n 1 | sed -e 's/^ARCH //')
  # vazio → resposta sem a linha ARCH = nao-consegui (nunca "arquitetura outra"); lida e diferente → arquitetura
  [ -n "$arch" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha ARCH"; return 0; }
  [ "$arch" = "Linux aarch64" ] || { STATE=arquitetura; DETAIL="o nó é '${arch:-?}' e o pin cobre Linux aarch64"; return 0; }
  node=$(printf '%s\n' "$out" | grep -E '^NODE ' | head -n 1)
  case "$node" in
    "NODE ausente") STATE=ausente; DETAIL="não há ~/.local/bin/node no nó" ;;
    "NODE "*) ver=$(printf '%s\n' "$node" | awk '{print $2}'); loc=$(printf '%s\n' "$node" | awk '{print $3}')
      if [ "$ver" = ERRO ]; then STATE=quebrado; DETAIL="existe e não roda: ~/.local/bin/node"
      elif [ "$ver" = "v$V" ] && [ "$loc" = certo ]; then STATE=ok; DETAIL="$ver em ~/.local/node-v$V-linux-arm64 (igual ao pin)"
      else STATE=diferente; DETAIL="o nó tem $ver ($loc do diretório do pin) e o pin é v$V"; fi ;;
    *) STATE=nao-consegui; DETAIL="linha NODE ausente na resposta do nó" ;;
  esac
}

report() { # imprime a linha do STATE e devolve o rc do check
  case "$STATE" in
    ok) say "ok: $DETAIL"; return 0 ;;
    ausente|diferente|quebrado) say "$STATE: $DETAIL"; return 1 ;;
    arquitetura) say "arquitetura: $DETAIL"; return 3 ;;
    *) say "NAO-CONSEGUI: $DETAIL"; return 2 ;;
  esac
}

probe
if [ "$cmd" = check ]; then report; exit $?; fi

# install: já igual ao pin = nada a fazer; não sei / arquitetura outra = para aqui
case "$STATE" in
  ok) report; exit 0 ;;
  nao-consegui|arquitetura) report; exit $? ;;
esac
say "instalando v$V no $HOST (hoje: $STATE)"
# vazio → sem FIM é incompleto (rc 2); falhou/ilegível → o rc do ssh/remoto decide abaixo
out=$(remote_install | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- "$V" "$SHA" 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^(STEP|RECUSO) ' | sed -e 's/^/NODEJS remoto: /'
case $rc in
  0) ;;
  3|4|5) say "recusado/falhou no nó (rc $rc): nada foi trocado"; exit "$rc" ;;
  255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;
  *) die 1 "o instalador remoto saiu com rc $rc; rode check" ;;
esac
printf '%s\n' "$out" | grep -qx 'FIM' || die 2 "NAO-CONSEGUI: o instalador remoto terminou sem a sentinela FIM; rode check"
# a conferência final usa o mesmo report do check: não consegui ler = rc 2, li e não está ok = rc 1, ok = rc 0
probe
report; exit $?
