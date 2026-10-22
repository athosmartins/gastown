#!/usr/bin/env bash
# hetzner-chromium.sh — Chromium do Playwright no nó Linux (Hetzner) em nível de USUÁRIO, para os e2e do WA que pulam lá (ga-aptlug). Roda no MINI, fala com o nó por ssh e só escreve em ~/gt-remote/pw-chromium/env do usuário do nó. Doc: docs/runbooks/hetzner-chromium.md
#
# Contents
#   Para que serve · Subcomandos · Códigos de saída · Por que é seguro · Limites
#
# PARA QUE SERVE: dois arquivos de teste do WA (test_terrenos_construtoras_e2e_wa_gnvcqe.py, test_pessoas_admin_e2e_wa_jkr1bh_6.py) dão 49 pulos no nó com "Chromium do Playwright não instalado nesta máquina". A bead dizia que o navegador
#   pede apt/sudo; não pede: o navegador vai para uma pasta do usuário e as 13 bibliotecas de sistema vêm de .deb baixados (`apt-get download`, sem root) e extraídos com `dpkg -x`, achados por LD_LIBRARY_PATH — o mesmo desenho do bootstrap do scrape.
# SUBCOMANDOS: check [--pin ARQ] · install [--pin ARQ]      (pin padrão: scripts/hetzner-chromium.pin; HETZNER_CHROMIUM_PIN troca)
#   check    só LÊ o nó (e abre o navegador de verdade, 1 s, numa página local). ok = marcador `ready` igual ao pin + o venv-wa tem o Playwright do pin + sha256 do headless shell igual ao pin + ldd sem biblioteca faltando + o navegador abre.
#   install  1) tira o marcador `ready` (a partir daqui os e2e voltam a pular) 2) `playwright install chromium-headless-shell` do venv-wa, na pasta do usuário 3) confere o sha256 do headless shell contra o pin ANTES de executá-lo
#            4) `apt-get download` das DEB_PACKAGES do pin + `dpkg -x` 5) ldd sem faltando 6) abre o navegador de verdade 7) SÓ ENTÃO grava o marcador. Já está igual ao pin = não baixa nada (rc 0).
# CÓDIGOS: 0 ok / instalado · 1 check: ausente, quebrado ou diferente do pin · install: depois de instalar a conferência final LEU o nó e ele não está ok (se não conseguiu ler é rc 2) · 2 NÃO consegui saber (pin ilegível ou ambíguo, ssh caiu,
#   saída que não reconheço; nunca vira "ausente") · 3 o nó não é o que o pin cobre (SO/arquitetura) · 4 recusado (venv-wa com outro Playwright, sha256 do navegador não confere, biblioteca faltando, o navegador não abre) · 5 download falhou
#   (playwright install ou apt-get download) · 64 uso errado (nunca 2, que é "não consegui saber")
# POR QUE É SEGURO: o marcador é a ÚNICA coisa que liga o Chromium aos testes (mbp-run.sh só exporta PLAYWRIGHT_BROWSERS_PATH e LD_LIBRARY_PATH, juntas, quando ele existe). Meia instalação seria PIOR que nenhuma: navegador sem biblioteca
#   troca PULADO por VERMELHO (o erro "Target page, context or browser has been closed" não casa a cláusula de skip dos testes). Por isso o marcador cai no começo do install e só volta no fim, depois de o navegador abrir; qualquer recusa
#   no meio deixa o nó SEM marcador = pulando como antes. O pin é DADO (lido por grep, nunca `source`) e versão, hash e nomes de pacote passam por regex antes de ir ao ssh. Não usa sudo, não toca no apt do sistema nem em ~/.local.
# LIMITES: duas instalações ao mesmo tempo não são serializadas (não há lock) e um install durante uma bateria troca arquivos que um Chromium em curso pode estar usando: rode um install por vez, fora de bateria. Os .deb extraídos entram no
#   LD_LIBRARY_PATH com precedência sobre as bibliotecas do sistema (hoje nenhum soname deles existe no ld cache do nó, então só acrescentam; se isso mudar, refaça o install). Selftest: scripts/hetzner-chromium.selftest.sh (ssh, uname, apt-get,
#   dpkg, ldd e o python do venv-wa são stubs; o script remoto roda de verdade num HOME temporário).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH_BIN=${MBP_SSH:-ssh}; HOST=${HETZNER_NODE_HOST:-hetzner-teste}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
PIN=${HETZNER_CHROMIUM_PIN:-$HERE/hetzner-chromium.pin}
RE_VER='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; RE_SHA='^[0-9a-f]{64}$'; RE_DEBS='^[a-z0-9][a-z0-9.+-]*( [a-z0-9][a-z0-9.+-]*)*$'
say() { echo "CHROMIUM $*"; }
die() { local rc=$1; shift; say "$*"; exit "$rc"; }
usage() { echo "uso: hetzner-chromium.sh check|install [--pin ARQUIVO]" >&2; exit 64; }

cmd=${1:-}; [ -n "$cmd" ] && shift
case "$cmd" in check|install) ;; *) usage ;; esac
while [ $# -gt 0 ]; do case "$1" in --pin) [ $# -ge 2 ] || usage; PIN=$2; shift 2 ;; *) usage ;; esac; done

# O pin é DADO: três linhas KEY=valor, cada uma exatamente uma vez. Ausente, ilegível, repetida ou fora do formato = rc 2 (não sei o que o nó deve ter), nunca um valor padrão.
pin_get() { local n; n=$(grep -c -E "^$1=" "$PIN" 2>/dev/null) || n=0; [ "$n" = 1 ] || return 1; grep -E "^$1=" "$PIN" | sed -e "s/^$1=//"; }
[ -r "$PIN" ] || die 2 "NAO-CONSEGUI: pin ilegível ou ausente ($PIN)"
# vazio → pin_get devolve 1 (rc 2 abaixo); falhou/ilegível → idem: nunca cai num valor padrão
PW=$(pin_get PLAYWRIGHT_VERSION) || die 2 "NAO-CONSEGUI: $PIN não tem PLAYWRIGHT_VERSION exatamente uma vez"
SHA=$(pin_get HEADLESS_SHELL_SHA256_LINUX_ARM64) || die 2 "NAO-CONSEGUI: $PIN não tem HEADLESS_SHELL_SHA256_LINUX_ARM64 exatamente uma vez"
DEBS=$(pin_get DEB_PACKAGES) || die 2 "NAO-CONSEGUI: $PIN não tem DEB_PACKAGES exatamente uma vez"
[[ "$PW" =~ $RE_VER ]] || die 2 "NAO-CONSEGUI: PLAYWRIGHT_VERSION fora do formato N.N.N ($PW)"
[[ "$SHA" =~ $RE_SHA ]] || die 2 "NAO-CONSEGUI: HEADLESS_SHELL_SHA256_LINUX_ARM64 fora do formato (64 hex minúsculos)"
[[ "$DEBS" =~ $RE_DEBS ]] || die 2 "NAO-CONSEGUI: DEB_PACKAGES fora do formato (nomes de pacote separados por espaço)"

# O que os dois scripts remotos compartilham: onde mora o ambiente, como ler a versão do Playwright do venv-wa, onde está o headless shell e o teste de abrir o navegador (tem de imprimir CHROMIUM_OK).
remote_common() { cat <<'EOF'
D=$HOME/gt-remote/pw-chromium/env; V=$HOME/gt-remote/venv-wa
SMOKE='from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch(timeout=30000); pg = b.new_page(); pg.set_content("<p>ok</p>"); assert pg.inner_text("p") == "ok"; b.close()
print("CHROMIUM_OK")'
# vazio → sem venv-wa ou sem playwright nele: o chamador trata como "ausente" (nunca como igual ao pin); falhou/ilegível → idem
pw_ver() { "$V/bin/python" -c 'import importlib.metadata as m; print(m.version("playwright"))' 2>/dev/null | head -n 1; }
# vazio → nenhum headless shell em browsers/ (o chamador diz ausente); falhou/ilegível (pasta sem permissão) → idem, nunca um caminho inventado
find_bin() { find "$D/browsers" -type f \( -name headless_shell -o -name chrome-headless-shell \) 2>/dev/null | sort | head -n 1; }
EOF
}

# Só LÊ (e abre o navegador numa página local). Imprime ARCH, VENV, MARK e, se há marcador, BIN, LDD e LAUNCH, mais a sentinela FIM; sem a sentinela quem chama trata como "não consegui ler".
remote_probe() { remote_common; cat <<'EOF'
echo "ARCH $(uname -s) $(uname -m)"
ver=$(pw_ver); [ -n "$ver" ] || ver=ausente
echo "VENV $ver"
if [ ! -e "$D/ready" ]; then echo "MARK ausente"; echo FIM; exit 0; fi
# vazio → chave sem valor no marcador = "ilegivel" (o mini diz quebrado); falhou/ilegível (grep não lê) → idem
mver=$(grep -E '^PLAYWRIGHT_VERSION=' "$D/ready" 2>/dev/null | head -n 1 | sed -e 's/^PLAYWRIGHT_VERSION=//'); msha=$(grep -E '^HEADLESS_SHELL_SHA256=' "$D/ready" 2>/dev/null | head -n 1 | sed -e 's/^HEADLESS_SHELL_SHA256=//')
echo "MARK ${mver:-ilegivel} ${msha:-ilegivel}"
bin=$(find_bin)
if [ -n "$bin" ]; then echo "BIN $(sha256sum "$bin" 2>/dev/null | awk '{print $1}')"; else echo "BIN ausente"; fi
# vazio → sem libpath.txt = sem biblioteca extraída: LDD erro e LAUNCH falhou (o mini diz quebrado); falhou/ilegível → idem
lp=$(head -n 1 "$D/libpath.txt" 2>/dev/null)
if [ -n "$bin" ] && [ -n "$lp" ]; then
  if o=$(LD_LIBRARY_PATH=$lp ldd "$bin" 2>&1); then echo "LDD $(printf '%s\n' "$o" | grep -c 'not found' || true)"; else echo "LDD erro"; fi
  if o=$(LD_LIBRARY_PATH=$lp PLAYWRIGHT_BROWSERS_PATH=$D/browsers "$V/bin/python" -c "$SMOKE" 2>&1) && printf '%s\n' "$o" | grep -qx CHROMIUM_OK; then echo "LAUNCH ok"; else echo "LAUNCH falhou"; fi
else echo "LDD erro"; echo "LAUNCH falhou"; fi
echo FIM
EOF
}

# Escreve só em ~/gt-remote/pw-chromium/env. Códigos: 3 arquitetura · 4 recusado · 5 download · 6 outra falha. O marcador `ready` cai no começo e é a ÚLTIMA coisa que volta.
remote_install() { remote_common; cat <<'EOF'
set -eu
PW=$1; SHA=$2; shift 2
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || { echo "RECUSO arquitetura $(uname -s) $(uname -m)"; exit 3; }
[ -x "$V/bin/python" ] || { echo "RECUSO sem $V/bin/python (o venv do WA)"; exit 4; }
got=$(pw_ver) || got=
[ "$got" = "$PW" ] || { echo "RECUSO o playwright do venv-wa é '${got:-nada}' e o pin é $PW"; exit 4; }
mkdir -p "$D/browsers" "$D/debs" "$D/root"
rm -f "$D/ready" "$D/ready.tmp"
echo "STEP marcador-removido (os e2e pulam até o fim deste install)"
PLAYWRIGHT_BROWSERS_PATH=$D/browsers "$V/bin/python" -m playwright install chromium-headless-shell > "$D/pw-install.log" 2>&1 || { tail -n 3 "$D/pw-install.log"; echo "RECUSO playwright install falhou"; exit 5; }
bin=$(find_bin)
[ -n "$bin" ] || { echo "RECUSO o headless shell não está em $D/browsers"; exit 4; }
printf '%s  %s\n' "$SHA" "$bin" | sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 do navegador não confere com o pin"; exit 4; }
echo "STEP sha256-ok"
# debs/ e root/ de um install anterior saem antes: um .deb de versão antiga extraído por último venceria o novo (o marcador já caiu, nada usa esta pasta agora)
find "$D/debs" "$D/root" -mindepth 1 -delete
# os nomes de pacote vêm do pin, já conferidos por regex no mini; chegam como um argumento cada ("$@")
( cd "$D/debs" && apt-get download "$@" >/dev/null 2>"$D/apt-download.err" ) || { echo "RECUSO apt-get download falhou"; exit 5; }
n=0
for f in "$D"/debs/*.deb; do [ -f "$f" ] || continue; dpkg -x "$f" "$D/root" || { echo "RECUSO dpkg -x falhou em $f"; exit 4; }; n=$((n+1)); done
[ "$n" -gt 0 ] || { echo "RECUSO nenhum .deb baixado"; exit 5; }
echo "STEP extraiu $n .deb"
lp=$(find "$D/root" -name '*.so*' | sed -e 's|/[^/]*$||' | sort -u | paste -sd: -)
[ -n "$lp" ] || { echo "RECUSO nenhuma biblioteca extraída dos .deb"; exit 4; }
printf '%s\n' "$lp" > "$D/libpath.txt"
o=$(LD_LIBRARY_PATH=$lp ldd "$bin" 2>&1) || { echo "RECUSO o ldd não rodou no navegador"; exit 4; }
miss=$(printf '%s\n' "$o" | grep -c 'not found' || true)
[ "$miss" = 0 ] || { echo "RECUSO $miss biblioteca(s) faltando no navegador:"; printf '%s\n' "$o" | grep 'not found' | head -n 5; exit 4; }
echo "STEP ldd-sem-faltando"
o=$(LD_LIBRARY_PATH=$lp PLAYWRIGHT_BROWSERS_PATH=$D/browsers "$V/bin/python" -c "$SMOKE" 2>&1) || { echo "RECUSO o navegador não abriu: $(printf '%s' "$o" | tail -n 1 | cut -c1-200)"; exit 4; }
printf '%s\n' "$o" | grep -qx CHROMIUM_OK || { echo "RECUSO o teste de abrir o navegador não imprimiu CHROMIUM_OK"; exit 4; }
echo "STEP navegador-abriu"
printf 'PLAYWRIGHT_VERSION=%s\nHEADLESS_SHELL_SHA256=%s\nINSTALLED_AT=%s\n' "$PW" "$SHA" "$(date -u +%FT%TZ)" > "$D/ready.tmp" && mv "$D/ready.tmp" "$D/ready"
echo "STEP marcador-gravado"
echo FIM
EOF
}

# Pergunta ao nó (só leitura) e classifica em STATE: ok · ausente · diferente · quebrado · arquitetura · nao-consegui. Não imprime nem sai: quem chama decide o rc.
STATE=; DETAIL=
get() { printf '%s\n' "$out" | grep -E "^$1 " | head -n 1 | sed -e "s/^$1 //"; }
probe() {
  local rc arch vver mark mver msha bsha lddn lnch
  # vazio → sem sentinela FIM = nao-consegui (nunca "ausente"); falhou/ilegível (ssh rc≠0) → idem
  out=$(remote_probe | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- 2>/dev/null); rc=$?
  if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'FIM'; then STATE=nao-consegui; DETAIL="ssh para $HOST caiu (rc $rc) ou a resposta veio incompleta"; return 0; fi
  arch=$(get ARCH)
  # vazio → resposta sem a linha ARCH = nao-consegui (nunca "arquitetura outra"); lida e diferente → arquitetura
  [ -n "$arch" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha ARCH"; return 0; }
  [ "$arch" = "Linux aarch64" ] || { STATE=arquitetura; DETAIL="o nó é '${arch:-?}' e o pin cobre Linux aarch64"; return 0; }
  vver=$(get VENV); mark=$(get MARK)
  [ -n "$vver" ] && [ -n "$mark" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha VENV ou MARK"; return 0; }
  [ "$mark" != ausente ] || { STATE=ausente; DETAIL="não há o marcador ~/gt-remote/pw-chromium/env/ready no nó (os e2e do WA pulam, como antes)"; return 0; }
  mver=$(printf '%s' "$mark" | awk '{print $1}'); msha=$(printf '%s' "$mark" | awk '{print $2}')
  if [ "$mver" = ilegivel ] || [ "$msha" = ilegivel ]; then STATE=quebrado; DETAIL="o marcador existe e não tem PLAYWRIGHT_VERSION/HEADLESS_SHELL_SHA256 legíveis"; return 0; fi
  if [ "$vver" != "$PW" ]; then STATE=diferente; DETAIL="o venv-wa tem o Playwright '$vver' e o pin é $PW (o navegador instalado é de outro build)"; return 0; fi
  if [ "$mver" != "$PW" ] || [ "$msha" != "$SHA" ]; then STATE=diferente; DETAIL="o marcador diz Playwright $mver e sha ${msha:0:12}…, o pin é $PW e ${SHA:0:12}…"; return 0; fi
  bsha=$(get BIN); lddn=$(get LDD); lnch=$(get LAUNCH)
  [ -n "$bsha" ] && [ -n "$lddn" ] && [ -n "$lnch" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem BIN, LDD ou LAUNCH (ou o sha256sum não leu o navegador)"; return 0; }
  if [ "$bsha" = ausente ]; then STATE=quebrado; DETAIL="o marcador existe e o headless shell sumiu de ~/gt-remote/pw-chromium/env/browsers"
  elif [ "$bsha" != "$SHA" ]; then STATE=quebrado; DETAIL="o headless shell do nó tem sha256 ${bsha:0:12}… e o pin é ${SHA:0:12}…"
  elif [ "$lddn" != 0 ]; then STATE=quebrado; DETAIL="ldd do navegador: $lddn biblioteca(s) faltando (ou o ldd não rodou)"
  elif [ "$lnch" != ok ]; then STATE=quebrado; DETAIL="o navegador não abriu"
  else STATE=ok; DETAIL="Playwright $PW, headless shell sha256 ${SHA:0:12}…, ldd sem faltando, o navegador abre"; fi
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
say "instalando Playwright $PW / Chromium no $HOST (hoje: $STATE)"
# vazio → sem FIM é incompleto (rc 2); falhou/ilegível → o rc do ssh/remoto decide abaixo
# $DEBS sem aspas de propósito: um argumento por pacote (o regex acima só deixa nomes de pacote separados por espaço)
out=$(remote_install | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- "$PW" "$SHA" $DEBS 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^(STEP|RECUSO) ' | sed -e 's/^/CHROMIUM remoto: /'
case $rc in
  0) ;;
  3|4|5) say "recusado/falhou no nó (rc $rc): sem marcador, os e2e continuam pulando"; exit "$rc" ;;
  255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;
  *) die 1 "o instalador remoto saiu com rc $rc; rode check" ;;
esac
printf '%s\n' "$out" | grep -qx 'FIM' || die 2 "NAO-CONSEGUI: o instalador remoto terminou sem a sentinela FIM; rode check"
# a conferência final usa o mesmo report do check: não consegui ler = rc 2, li e não está ok = rc 1, ok = rc 0
probe
report; exit $?
