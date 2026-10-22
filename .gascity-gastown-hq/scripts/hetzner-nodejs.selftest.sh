#!/usr/bin/env bash
# hetzner-nodejs.selftest.sh — hermético: ssh, curl e uname são stubs; o script REMOTO roda de verdade, num HOME temporário, com um tarball falso (um `node` que só responde --version). (ga-2hd02v.4.9)
#
# Contents
#   Casos · Mutantes
#
# CASOS: check sem nada = ausente (rc 1) · install feliz (link, versão, sem sobra do diretório temporário, URL https da versão do pin) · install de novo não baixa nada · tarball adulterado e hash do pin errado = rc 4 e nada instalado
#   · download que falha = rc 5, e o node antigo continua valendo · nó x86_64 = rc 3 (check e install), sem download · pin ausente, com versão fora do formato (injeção) ou com linha repetida = rc 2 SEM chamar o ssh
#   · ssh que cai (antes e depois de responder) e resposta sem a sentinela = rc 2, nunca "ausente" · ~/.local/bin/node que é arquivo comum = rc 4 e o arquivo fica · upgrade de versão mantém o diretório antigo
#   · diretório da versão que já existe e não é o node certo = rc 4 · tarball cujo binário diz outra versão = rc 4 · link quebrado = "quebrado" no check e o install conserta · node certo fora do diretório do pin = "diferente".
# MUTANTES: cada um troca UM trecho do script por uma versão frouxa (python3, substring exata e única); o caso que deveria pegá-lo tem de falhar. Mutante que sobrevive = caso faltando.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/hetzner-nodejs.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hnjs-selftest.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P)   # pwd -P: no macOS /var é link para /private/var e o readlink -f do script remoto resolve
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
STUBS="$T/stubs"; FIX="$T/fix"; FAKE_HOME="$T/home"; STUB_LOG="$T/stub.log"; PINF="$T/pin"; STUB_COUNT="$T/probe-count"; LIBS_DIR="$T/libs"
mkdir -p "$STUBS" "$FIX" "$LIBS_DIR"
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || bad "$1: esperado '$2', veio '$3'"; }
has() { grep -q -E -e "$3" "$2" 2>/dev/null && ok "$1" || bad "$1: '$3' ausente em $2"; }
hasnt() { grep -q -E -e "$3" "$2" 2>/dev/null && bad "$1: '$3' presente em $2" || ok "$1"; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

cat > "$STUBS/ssh" <<'STUB'
#!/usr/bin/env bash
echo "SSH:$*" >> "$STUB_LOG"
[ -n "${STUB_SSH_RC:-}" ] && exit "$STUB_SSH_RC"
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done
shift   # o host
script=$(cat); kind=probe; case "$script" in *RECUSO*) kind=install ;; esac   # só o script de instalação (node ou jsdom) tem linhas RECUSO; as sondas só leem
[ -n "${STUB_CORRUPT_LOCK:-}" ] && script=$(printf '%s\n' "$script" | sed "s/^LOCKB64='e/LOCKB64='f/")   # o lock chega ao nó com o 1o caractere trocado
if [ "$kind" = probe ]; then
  n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
  [ "$n" = "${STUB_SSH_FAIL_PROBE_N:-0}" ] && exit 255   # a N-ésima sonda cai (a 2a é a conferência final do install)
else
  [ -n "${STUB_SSH_RC_INSTALL:-}" ] && exit "$STUB_SSH_RC_INSTALL"   # cai ANTES de o install rodar
fi
out=$(printf '%s\n' "$script" | HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash -c "$*"); rc=$?
[ -n "${STUB_SSH_DROP_FIM:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = install ] && [ -n "${STUB_SSH_DROP_FIM_INSTALL:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = probe ] && [ -n "${STUB_SSH_DROP_ARCH:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^ARCH ')
printf '%s\n' "$out"
[ -n "${STUB_SSH_RC_AFTER:-}" ] && exit "$STUB_SSH_RC_AFTER"
[ "$kind" = install ] && [ -n "${STUB_SSH_RC_AFTER_INSTALL:-}" ] && exit "$STUB_SSH_RC_AFTER_INSTALL"   # cai DEPOIS de o install rodar
exit $rc
STUB
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
echo "CURL:$*" >> "$STUB_LOG"
out=; url=; prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
case "${STUB_CURL:-ok}" in
  fail) exit 22 ;;
  tamper) cp "$FIX/tamper.tar.xz" "$out" ;;
  *) f="$FIX/$(basename "$url")"; [ -f "$f" ] || exit 22; cp "$f" "$out" ;;
esac
STUB
cat > "$STUBS/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -s) echo "${STUB_OS:-Linux}" ;; -m) echo "${STUB_ARCH:-aarch64}" ;; *) echo "${STUB_OS:-Linux}" ;; esac
STUB
command -v sha256sum >/dev/null 2>&1 || printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$STUBS/sha256sum"
command -v timeout >/dev/null 2>&1 || printf '#!/bin/sh\nshift\nexec "$@"\n' > "$STUBS/timeout"   # macOS não tem timeout: o falso só repassa o comando
printf 'x' | base64 | base64 -d >/dev/null 2>&1 || printf '#!/usr/bin/env bash\n[ "${1:-}" = -d ] && shift && set -- -D "$@"\nexec /usr/bin/base64 "$@"\n' > "$STUBS/base64"   # macOS antigo só decodifica com -D
# npm falso (só entende `ci`): registra os argumentos e os arquivos que viu, e cria node_modules/jsdom com a versão que o package.json do diretório atual pede
cat > "$FIX/npm.sh" <<'STUB'
#!/bin/sh
echo "NPM:$* @ $(LC_ALL=C ls | tr '\n' ' ')" >> "$STUB_LOG"
[ "$1" = ci ] || exit 2
[ "${STUB_NPM:-ok}" = fail ] && { echo "npm ERR! network" >&2; exit 1; }
v=$(sed -n 's/.*"jsdom": *"\([^"]*\)".*/\1/p' package.json | head -n 1)
[ "${STUB_NPM:-ok}" = versao ] && v=0.0.1
mkdir -p node_modules/jsdom && printf '{\n  "name": "jsdom",\n  "version": "%s"\n}\n' "$v" > node_modules/jsdom/package.json
[ "${STUB_NPM:-ok}" = quebrado ] && : > node_modules/jsdom/QUEBRADO
exit 0
STUB
chmod +x "$STUBS"/*
export STUB_LOG STUB_COUNT FAKE_HOME STUBS FIX MBP_SSH="$STUBS/ssh" HETZNER_NODE_HOST=fake HETZNER_NODEJS_PIN="$PINF" HETZNER_NODEJS_LIBS="$LIBS_DIR"

# mkfix VERSÃO [VERSÃO QUE O BINÁRIO DIZ]: monta node-v<VERSÃO>-linux-arm64.tar.xz com bin/node e bin/npm falsos; imprime o sha256
# o node falso responde --version e, em `-e` (a prova de que o jsdom carrega), olha se há node_modules/jsdom em $NODE_PATH sem o marcador QUEBRADO
mkfix() {
  local v=$1 says=${2:-$1} d="$T/mk/node-v$1-linux-arm64"
  mkdir -p "$d/bin" && printf '#!/bin/sh\ncase "$1" in\n  --version) echo v%s ;;\n  -e) [ -f "$NODE_PATH/jsdom/package.json" ] && [ ! -e "$NODE_PATH/jsdom/QUEBRADO" ] ;;\nesac\n' "$says" > "$d/bin/node" && cp "$FIX/npm.sh" "$d/bin/npm" && chmod +x "$d/bin/node" "$d/bin/npm" || return 1
  tar -cJf "$FIX/node-v$v-linux-arm64.tar.xz" -C "$T/mk" "node-v$v-linux-arm64" || return 1
  find "$T/mk" -mindepth 1 -delete; sha_of "$FIX/node-v$v-linux-arm64.tar.xz"
}
mkpin() { printf '# pin de teste\nNODE_VERSION=%s\nNODE_SHA256_LINUX_ARM64=%s\n' "$1" "$2" > "$PINF"; }
reset() { find "$FAKE_HOME" -mindepth 1 -delete 2>/dev/null; mkdir -p "$FAKE_HOME/.local/bin"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; unset STUB_SSH_RC STUB_SSH_DROP_FIM STUB_SSH_RC_AFTER STUB_SSH_RC_INSTALL STUB_SSH_RC_AFTER_INSTALL STUB_SSH_DROP_FIM_INSTALL STUB_SSH_DROP_ARCH STUB_SSH_FAIL_PROBE_N STUB_CURL STUB_OS STUB_ARCH STUB_NPM STUB_CORRUPT_LOCK; }
run() { ( cd "$T" && bash "${SCRIPT:-$S}" "$@" > "$T/out" 2>"$T/err" ); echo $?; }   # cwd = o temporário: o mutante sem regex EXECUTA a injeção, e o que ela criar não pode cair no repositório
nodever() { "$FAKE_HOME/.local/bin/node" --version 2>/dev/null; }
leftover() { find "$FAKE_HOME/.local" -maxdepth 1 -name '.nodejs-install.*' 2>/dev/null | wc -l | tr -d ' '; }
printf 'garbage-que-nao-e-o-tarball\n' > "$FIX/tamper.tar.xz"
SHA9=$(mkfix 9.9.9) || { echo "FAIL não montei o fixture (falta tar/xz?)"; exit 2; }
SHA8=$(mkfix 9.9.8) || exit 2
SHAL=$(mkfix 9.9.7 9.9.6) || exit 2   # 9.9.7: o binário diz v9.9.6 (hash certo, binário mentindo)

c_vazio()   { reset; mkpin 9.9.9 "$SHA9"; local rc; rc=$(run check); eq "check sem nada: rc 1" 1 "$rc"; has "…diz ausente (não 'não consegui')" "$T/out" '^NODEJS ausente'; }
c_feliz()   { reset; mkpin 9.9.9 "$SHA9"; local rc; rc=$(run install); eq "install feliz: rc 0" 0 "$rc"; eq "…node responde v9.9.9" v9.9.9 "$(nodever)"
  [ -L "$FAKE_HOME/.local/bin/node" ] && ok "…~/.local/bin/node é symlink" || bad "…~/.local/bin/node não é symlink"
  eq "…sem sobra de diretório temporário" 0 "$(leftover)"; has "…baixou da URL https da versão do pin" "$STUB_LOG" 'CURL:.*https://nodejs\.org/dist/v9\.9\.9/node-v9\.9\.9-linux-arm64\.tar\.xz'; has "…curl só aceita https" "$STUB_LOG" "proto =https"
  rc=$(run check); eq "check depois: rc 0" 0 "$rc"; has "…diz ok" "$T/out" '^NODEJS ok'; }
c_idem()    { reset; mkpin 9.9.9 "$SHA9"; run install >/dev/null; : > "$STUB_LOG"; local rc; rc=$(run install); eq "install de novo: rc 0" 0 "$rc"; hasnt "…não baixa nada" "$STUB_LOG" 'CURL:'; }
c_adulterado() { reset; mkpin 9.9.9 "$SHA9"; STUB_CURL=tamper; export STUB_CURL; local rc; rc=$(run install); eq "tarball adulterado: rc 4" 4 "$rc"; has "…diz que o sha256 não confere" "$T/out" 'sha256'
  [ -e "$FAKE_HOME/.local/bin/node" ] || [ -L "$FAKE_HOME/.local/bin/node" ] && bad "…nada pode ser instalado" || ok "…nada instalado"; eq "…sem sobra de diretório temporário" 0 "$(leftover)"; }
c_pin_errado() { reset; mkpin 9.9.9 "$(printf '%064d' 0)"; local rc; rc=$(run install); eq "hash do pin errado: rc 4" 4 "$rc"; [ -L "$FAKE_HOME/.local/bin/node" ] && bad "…nada pode ser instalado" || ok "…nada instalado"; }
c_dl_falha() { reset; mkpin 9.9.8 "$SHA8"; run install >/dev/null; mkpin 9.9.9 "$SHA9"; STUB_CURL=fail; export STUB_CURL; local rc; rc=$(run install); eq "download falha: rc 5" 5 "$rc"
  eq "…o node antigo continua valendo" v9.9.8 "$(nodever)"; eq "…sem sobra de diretório temporário" 0 "$(leftover)"; }
c_arch()    { reset; mkpin 9.9.9 "$SHA9"; STUB_ARCH=x86_64; export STUB_ARCH; local rc; rc=$(run check); eq "check em x86_64: rc 3" 3 "$rc"; rc=$(run install); eq "install em x86_64: rc 3" 3 "$rc"; hasnt "…não baixa nada" "$STUB_LOG" 'CURL:'; }
c_pin_ausente() { reset; local rc; rc=$(run check --pin "$T/nao-existe"); eq "pin ausente: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_injecao() { reset; printf 'NODE_VERSION=9.9.9; touch %s/pwned\nNODE_SHA256_LINUX_ARM64=%s\n' "$T" "$SHA9" > "$PINF"; local rc; rc=$(run install); eq "versão com injeção: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; [ -e "$T/pwned" ] && bad "…o comando injetado rodou" || ok "…nada injetado rodou"; }
c_repetida() { reset; printf 'NODE_VERSION=9.9.9\nNODE_VERSION=9.9.8\nNODE_SHA256_LINUX_ARM64=%s\n' "$SHA9" > "$PINF"; local rc; rc=$(run check); eq "NODE_VERSION repetida: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_ssh_cai() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_RC=255; export STUB_SSH_RC; local rc; rc=$(run check); eq "ssh caiu: rc 2" 2 "$rc"; has "…NAO-CONSEGUI, não 'ausente'" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz ausente" "$T/out" '^NODEJS ausente'; }
c_ssh_cai_depois() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_RC_AFTER=255; export STUB_SSH_RC_AFTER; local rc; rc=$(run check); eq "ssh caiu depois de responder: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_sem_fim() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_DROP_FIM=1; export STUB_SSH_DROP_FIM; local rc; rc=$(run check); eq "resposta sem a sentinela FIM: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_arquivo() { reset; mkpin 9.9.9 "$SHA9"; printf '#!/bin/sh\necho v1.2.3\n' > "$FAKE_HOME/.local/bin/node"; chmod +x "$FAKE_HOME/.local/bin/node"; local rc; rc=$(run install); eq "bin/node é arquivo comum: rc 4" 4 "$rc"
  has "…o arquivo alheio fica" "$FAKE_HOME/.local/bin/node" 'echo v1\.2\.3'; hasnt "…nada baixado" "$STUB_LOG" 'CURL:'; }
c_upgrade() { reset; mkpin 9.9.8 "$SHA8"; run install >/dev/null; mkpin 9.9.9 "$SHA9"; local rc; rc=$(run check); eq "check com outra versão instalada: rc 1" 1 "$rc"; has "…diz diferente" "$T/out" '^NODEJS diferente'
  rc=$(run install); eq "upgrade: rc 0" 0 "$rc"; eq "…o link agora é v9.9.9" v9.9.9 "$(nodever)"; [ -x "$FAKE_HOME/.local/node-v9.9.8-linux-arm64/bin/node" ] && ok "…o diretório antigo continua lá" || bad "…o diretório antigo sumiu"; }
c_dir_errado() { reset; mkpin 9.9.9 "$SHA9"; mkdir -p "$FAKE_HOME/.local/node-v9.9.9-linux-arm64/bin"; printf '#!/bin/sh\necho v0.0.1\n' > "$FAKE_HOME/.local/node-v9.9.9-linux-arm64/bin/node"; chmod +x "$FAKE_HOME/.local/node-v9.9.9-linux-arm64/bin/node"
  local rc; rc=$(run install); eq "diretório da versão existe e não é o node: rc 4" 4 "$rc"; has "…não mexe nele" "$FAKE_HOME/.local/node-v9.9.9-linux-arm64/bin/node" 'v0\.0\.1'; [ -L "$FAKE_HOME/.local/bin/node" ] && bad "…não pode linkar" || ok "…nada linkado"; }
c_binario_mente() { reset; mkpin 9.9.7 "$SHAL"; local rc; rc=$(run install); eq "binário diz outra versão: rc 4" 4 "$rc"; has "…a recusa nomeia o que o binário disse" "$T/out" "diz 'v9\.9\.6'"; [ -L "$FAKE_HOME/.local/bin/node" ] && bad "…não pode linkar" || ok "…nada linkado"; }
c_quebrado() { reset; mkpin 9.9.9 "$SHA9"; ln -s /nao/existe "$FAKE_HOME/.local/bin/node"; local rc; rc=$(run check); eq "link quebrado: rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^NODEJS quebrado'; rc=$(run install); eq "install conserta: rc 0" 0 "$rc"; eq "…agora responde v9.9.9" v9.9.9 "$(nodever)"; }
c_fora_do_pin() { reset; mkpin 9.9.9 "$SHA9"; printf '#!/bin/sh\necho v9.9.9\n' > "$FAKE_HOME/.local/bin/node"; chmod +x "$FAKE_HOME/.local/bin/node"; local rc; rc=$(run check); eq "v9.9.9 fora do diretório do pin: rc 1" 1 "$rc"; has "…diz diferente (não ok)" "$T/out" '^NODEJS diferente'; }
c_versao_no_dir_certo() { reset; mkpin 9.9.9 "$SHA9"; local d="$FAKE_HOME/.local/node-v9.9.9-linux-arm64" rc; mkdir -p "$d/bin"; printf '#!/bin/sh\necho v9.9.8\n' > "$d/bin/node"; chmod +x "$d/bin/node"
  ln -s node-v9.9.9-linux-arm64 "$FAKE_HOME/.local/node"; ln -s ../node/bin/node "$FAKE_HOME/.local/bin/node"; rc=$(run check); eq "diretório certo com node de outra versão: rc 1" 1 "$rc"; has "…diz diferente (não ok)" "$T/out" '^NODEJS diferente'; }
c_install_ssh_cai() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_RC_INSTALL=255; export STUB_SSH_RC_INSTALL; local rc; rc=$(run install); eq "install: ssh cai na chamada do install: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'
  [ -L "$FAKE_HOME/.local/bin/node" ] && bad "…nada pode ser instalado" || ok "…nada instalado"; }
c_install_ssh_cai_depois() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_RC_AFTER_INSTALL=255; export STUB_SSH_RC_AFTER_INSTALL; local rc; rc=$(run install); eq "install: ssh cai DEPOIS de o install rodar (saída completa, rc 255): rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_install_sem_fim() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_DROP_FIM_INSTALL=1; export STUB_SSH_DROP_FIM_INSTALL; local rc; rc=$(run install); eq "install: resposta do install sem a sentinela FIM: rc 2" 2 "$rc"; has "…diz que faltou a sentinela" "$T/out" 'sentinela FIM'; }
c_conferencia_final_nao_le() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_FAIL_PROBE_N=2; export STUB_SSH_FAIL_PROBE_N; local rc; rc=$(run install); eq "install ok mas a sonda FINAL não consegue ler: rc 2 (não 1)" 2 "$rc"; has "…NAO-CONSEGUI, não 'a conferência não fechou'" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz 'verificado e não ok'" "$T/out" 'não fechou'; }
c_arch_sem_linha() { reset; mkpin 9.9.9 "$SHA9"; STUB_SSH_DROP_ARCH=1; export STUB_SSH_DROP_ARCH; local rc; rc=$(run check); eq "resposta com FIM mas sem a linha ARCH: rc 2 (não 3)" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz 'arquitetura'" "$T/out" '^NODEJS arquitetura'; }
c_home_symlink() { reset; mkpin 9.9.9 "$SHA9"; local real=$FAKE_HOME rc; ln -sfn "$real" "$T/homelink"; export FAKE_HOME="$T/homelink"; rc=$(run install); eq "HOME que cruza symlink: install rc 0" 0 "$rc"; rc=$(run check); eq "…e o check seguinte diz ok (rc 0), não 'diferente'" 0 "$rc"
  : > "$STUB_LOG"; rc=$(run install); eq "…e o install de novo não baixa nada (rc 0)" 0 "$rc"; hasnt "…sem curl" "$STUB_LOG" 'CURL:'; export FAKE_HOME="$real"; rm -f "$T/homelink"; }
c_usage() { reset; local rc; rc=$(run); eq "sem subcomando: rc 64 (uso errado), não 2" 64 "$rc"; rc=$(run install --pin); eq "--pin sem argumento: rc 64" 64 "$rc"; }

# ---- jsdom (ga-yoyyj1): `check|install jsdom` cuida do jsdom do pin em ~/.local/share/cdp-drive, o caminho onde os testes do WA o procuram ----
mklibs() { printf '{\n  "name": "fake-libs",\n  "dependencies": {\n    "jsdom": "%s"\n  }\n}\n' "$1" > "$LIBS_DIR/package.json"; printf '{"fake":"%s"}\n' "$2" > "$LIBS_DIR/package-lock.json"; sha_of "$LIBS_DIR/package-lock.json"; }   # VERSÃO TEXTO → imprime o sha256 do lock falso
mkpinj() { printf '# pin de teste\nNODE_VERSION=9.9.9\nNODE_SHA256_LINUX_ARM64=%s\nJSDOM_VERSION=%s\nJSDOM_LOCK_SHA256=%s\n' "$SHA9" "$1" "$2" > "$PINF"; }
jsetup() { reset; JSHA=$(mklibs 9.8.0 um); mkpinj 9.8.0 "$JSHA"; }   # nó vazio; pin com jsdom 9.8.0
jnode() { run install >/dev/null; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; }   # instala o node falso e zera log e contador de sondas
jleft() { find "$FAKE_HOME/.local/share" -maxdepth 1 -name '.jsdom-install.*' 2>/dev/null | wc -l | tr -d ' '; }
jlink() { [ -L "$FAKE_HOME/.local/share/cdp-drive" ]; }
jver() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$FAKE_HOME/.local/share/cdp-drive/node_modules/jsdom/package.json" 2>/dev/null | head -n 1; }
c_j_vazio() { jsetup; jnode; local rc; rc=$(run check jsdom); eq "check jsdom sem nada: rc 1" 1 "$rc"; has "…diz ausente (não 'não consegui')" "$T/out" '^NODEJS jsdom ausente'
  rc=$(run check); eq "…e o check do node (o que o guarda do PS chama) segue rc 0 sem jsdom" 0 "$rc"; hasnt "…sem falar de jsdom" "$T/out" 'jsdom'; }
c_j_feliz() { jsetup; jnode; local rc; rc=$(run install jsdom); eq "install jsdom: rc 0" 0 "$rc"; jlink && ok "…cdp-drive é symlink (o caminho que os testes do WA procuram)" || bad "…cdp-drive não é symlink"
  eq "…o jsdom que os testes enxergam é o do pin" 9.8.0 "$(jver)"; has "…npm ci sem rodar script de pacote" "$STUB_LOG" 'NPM:ci .*--ignore-scripts'
  has "…o npm viu o package.json e o lock" "$STUB_LOG" 'NPM:ci .* @ package-lock\.json package\.json'; has "…cache do npm no temporário, nada em ~/.npm" "$STUB_LOG" "NPM:ci .*--cache $FAKE_HOME/\.local/share/\.jsdom-install\."
  has "…registry fixo" "$STUB_LOG" 'NPM:ci .*--registry=https://registry\.npmjs\.org/'; eq "…sem sobra de diretório temporário" 0 "$(jleft)"
  rc=$(run check jsdom); eq "check jsdom depois: rc 0" 0 "$rc"; has "…diz ok" "$T/out" '^NODEJS jsdom ok'; }
c_j_idem() { jsetup; jnode; run install jsdom >/dev/null; : > "$STUB_LOG"; local rc; rc=$(run install jsdom); eq "install jsdom de novo: rc 0" 0 "$rc"; hasnt "…não roda npm" "$STUB_LOG" 'NPM:'; }
c_j_lock_local() { jsetup; jnode; printf '{"fake":"adulterado"}\n' > "$LIBS_DIR/package-lock.json"; local rc; rc=$(run install jsdom); eq "lock local que não bate com o pin: rc 4" 4 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_j_lock_no_no() { jsetup; jnode; STUB_CORRUPT_LOCK=1; export STUB_CORRUPT_LOCK; local rc; rc=$(run install jsdom); eq "lock que chega alterado ao nó: rc 4" 4 "$rc"; has "…recusa pelo sha256" "$T/out" 'RECUSO.*sha256'
  hasnt "…npm não rodou" "$STUB_LOG" 'NPM:'; jlink && bad "…nada linkado" || ok "…nada linkado"; }
c_j_npm_falha() { jsetup; jnode; STUB_NPM=fail; export STUB_NPM; local rc; rc=$(run install jsdom); eq "npm ci falha: rc 5" 5 "$rc"; jlink && bad "…nada linkado" || ok "…nada linkado"; eq "…sem sobra de diretório temporário" 0 "$(jleft)"; }
c_j_versao_errada() { jsetup; jnode; STUB_NPM=versao; export STUB_NPM; local rc; rc=$(run install jsdom); eq "o npm instala outra versão: rc 4" 4 "$rc"; has "…nomeia o que instalou" "$T/out" "diz '0\.0\.1'"; jlink && bad "…nada linkado" || ok "…nada linkado"; }
c_j_nao_carrega() { jsetup; jnode; STUB_NPM=quebrado; export STUB_NPM; local rc; rc=$(run install jsdom); eq "jsdom instalado que não carrega: rc 4" 4 "$rc"; jlink && bad "…nada linkado" || ok "…nada linkado"; }
c_j_dir_comum() { jsetup; jnode; mkdir -p "$FAKE_HOME/.local/share/cdp-drive/node_modules/outro"; local rc; rc=$(run check jsdom); eq "cdp-drive é diretório comum: check rc 1" 1 "$rc"; has "…diz diferente (não 'quebrado')" "$T/out" '^NODEJS jsdom diferente'
  rc=$(run install jsdom); eq "…e o install recusa: rc 4" 4 "$rc"; [ -d "$FAKE_HOME/.local/share/cdp-drive/node_modules/outro" ] && ok "…o conteúdo alheio fica" || bad "…o conteúdo alheio sumiu"; hasnt "…npm não rodou" "$STUB_LOG" 'NPM:'; }
c_j_dir_existe_errado() { jsetup; jnode; local d rc; d="$FAKE_HOME/.local/share/cdp-drive-jsdom-9.8.0-$(printf '%s' "$JSHA" | cut -c1-12)"; mkdir -p "$d/node_modules/jsdom"; printf '{\n  "name": "jsdom",\n  "version": "0.0.1"\n}\n' > "$d/node_modules/jsdom/package.json"
  rc=$(run install jsdom); eq "diretório da versão existe e não é o jsdom do pin: rc 4" 4 "$rc"; has "…não mexe nele" "$d/node_modules/jsdom/package.json" '0\.0\.1'; jlink && bad "…nada pode ser linkado" || ok "…nada linkado"; }
c_j_versao_no_dir_certo() { jsetup; jnode; run install jsdom >/dev/null; printf '{\n  "name": "jsdom",\n  "version": "9.8.9"\n}\n' > "$FAKE_HOME/.local/share/cdp-drive/node_modules/jsdom/package.json"; local rc; rc=$(run check jsdom)
  eq "diretório certo com outra versão de jsdom: check rc 1" 1 "$rc"; has "…diz diferente (não ok)" "$T/out" '^NODEJS jsdom diferente'; }
c_j_install_ssh_cai_depois() { jsetup; jnode; STUB_SSH_RC_AFTER_INSTALL=255; export STUB_SSH_RC_AFTER_INSTALL; local rc; rc=$(run install jsdom); eq "install jsdom: ssh cai DEPOIS de o install rodar: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_j_sem_node() { jsetup; local rc; rc=$(run install jsdom); eq "install jsdom sem o node no nó: rc 4" 4 "$rc"; has "…manda instalar o node antes" "$T/out" "rode 'install' antes"; hasnt "…npm não rodou" "$STUB_LOG" 'NPM:'; }
c_j_quebrado() { jsetup; jnode; run install jsdom >/dev/null; : > "$FAKE_HOME/.local/share/cdp-drive/node_modules/jsdom/QUEBRADO"; local rc; rc=$(run check jsdom); eq "jsdom que não carrega: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^NODEJS jsdom quebrado'
  rc=$(run install jsdom); eq "…o install não mexe no diretório da versão (imutável): rc 4" 4 "$rc"; [ -e "$FAKE_HOME/.local/share/cdp-drive/node_modules/jsdom/QUEBRADO" ] && ok "…o diretório fica como estava" || bad "…o diretório foi mexido"; }
c_j_link_quebrado() { jsetup; jnode; mkdir -p "$FAKE_HOME/.local/share"; ln -s /nao/existe "$FAKE_HOME/.local/share/cdp-drive"; local rc; rc=$(run check jsdom); eq "link quebrado: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^NODEJS jsdom quebrado'
  rc=$(run install jsdom); eq "install conserta: rc 0" 0 "$rc"; eq "…agora o jsdom é o do pin" 9.8.0 "$(jver)"; }
c_j_upgrade() { jsetup; jnode; run install jsdom >/dev/null; local old rc; old=$(find "$FAKE_HOME/.local/share" -maxdepth 1 -name 'cdp-drive-jsdom-*' | head -n 1); mkpinj 9.8.1 "$(mklibs 9.8.1 dois)"
  rc=$(run check jsdom); eq "pin com outra versão: check rc 1" 1 "$rc"; has "…diz diferente" "$T/out" '^NODEJS jsdom diferente'; rc=$(run install jsdom); eq "upgrade: rc 0" 0 "$rc"; eq "…o jsdom agora é 9.8.1" 9.8.1 "$(jver)"
  [ -d "$old/node_modules/jsdom" ] && ok "…o diretório antigo continua lá" || bad "…o diretório antigo sumiu"; }
c_j_mesmo_jsdom_outro_lock() { jsetup; jnode; run install jsdom >/dev/null; mkpinj 9.8.0 "$(mklibs 9.8.0 tres)"; local rc; rc=$(run check jsdom); eq "mesmo jsdom, outro lock (uma dependência mudou): check rc 1" 1 "$rc"; has "…diz diferente (a identidade é o lock)" "$T/out" '^NODEJS jsdom diferente'; }
c_j_pin_sem_jsdom() { reset; mkpin 9.9.9 "$SHA9"; local rc; rc=$(run check jsdom); eq "pin sem as chaves do jsdom: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_j_injecao() { jsetup; printf 'NODE_VERSION=9.9.9\nNODE_SHA256_LINUX_ARM64=%s\nJSDOM_VERSION=9.8.0; touch %s/pwned2\nJSDOM_LOCK_SHA256=%s\n' "$SHA9" "$T" "$JSHA" > "$PINF"; local rc; rc=$(run install jsdom); eq "JSDOM_VERSION com injeção: rc 2" 2 "$rc"
  hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; [ -e "$T/pwned2" ] && bad "…o comando injetado rodou" || ok "…nada injetado rodou"; }
c_j_hash_curto() { jsetup; mkpinj 9.8.0 abc123; local rc; rc=$(run check jsdom); eq "JSDOM_LOCK_SHA256 fora do formato: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_j_arch() { jsetup; STUB_ARCH=x86_64; export STUB_ARCH; local rc; rc=$(run check jsdom); eq "check jsdom em x86_64: rc 3" 3 "$rc"; rc=$(run install jsdom); eq "install jsdom em x86_64: rc 3" 3 "$rc"; hasnt "…npm não rodou" "$STUB_LOG" 'NPM:'; }
c_j_ssh_cai() { jsetup; jnode; STUB_SSH_RC=255; export STUB_SSH_RC; local rc; rc=$(run check jsdom); eq "ssh caiu: check jsdom rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz ausente" "$T/out" 'jsdom ausente'; }
c_j_conferencia_final() { jsetup; jnode; STUB_SSH_FAIL_PROBE_N=3; export STUB_SSH_FAIL_PROBE_N; local rc; rc=$(run install jsdom); eq "install jsdom ok mas a sonda FINAL não lê: rc 2 (não 1)" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_j_usage() { reset; local rc; rc=$(run check jsdom jsdom); eq "componente repetido: rc 64" 64 "$rc"; rc=$(run check outro); eq "componente desconhecido: rc 64" 64 "$rc"; }
CASES="c_vazio c_feliz c_idem c_adulterado c_pin_errado c_dl_falha c_arch c_pin_ausente c_injecao c_repetida c_ssh_cai c_ssh_cai_depois c_sem_fim c_arquivo c_upgrade c_dir_errado c_binario_mente c_quebrado c_fora_do_pin c_versao_no_dir_certo c_install_ssh_cai c_install_ssh_cai_depois c_install_sem_fim c_conferencia_final_nao_le c_arch_sem_linha c_home_symlink c_usage"
CASES="$CASES c_j_vazio c_j_feliz c_j_idem c_j_lock_local c_j_lock_no_no c_j_npm_falha c_j_versao_errada c_j_nao_carrega c_j_dir_comum c_j_dir_existe_errado c_j_sem_node c_j_quebrado c_j_link_quebrado c_j_upgrade c_j_mesmo_jsdom_outro_lock c_j_versao_no_dir_certo"
CASES="$CASES c_j_pin_sem_jsdom c_j_injecao c_j_hash_curto c_j_arch c_j_ssh_cai c_j_install_ssh_cai_depois c_j_conferencia_final c_j_usage"
for c in $CASES; do echo "== $c"; $c; done

# ---- mutantes: troca UMA substring exata e única do script; o caso apontado tem de FALHAR ----
mutant() {   # nome · trecho original · trecho frouxo · caso que tem de pegar
  local name=$1 old=$2 new=$3 case_fn=$4 res
  if ! python3 - "$S" "$old" "$new" > "$T/mut.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[2], sys.argv[3]
if src.count(old) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(old, new))
PY
  then bad "mutante $name: o trecho original não aparece exatamente uma vez no script (o script mudou?)"; return; fi
  res=$( ( SCRIPT="$T/mut.sh"; $case_fn ) 2>&1 )
  if printf '%s\n' "$res" | grep -q '^FAIL'; then ok "mutante $name morto por $case_fn"; else bad "mutante $name SOBREVIVEU a $case_fn"; fi
}
echo "== mutantes"
NL='
'
mutant sem-conferir-sha        '"$T/node.tar.xz" | sha256sum -c - >/dev/null 2>&1 ||'        '"$T/node.tar.xz" | cat >/dev/null 2>&1 ||'  c_adulterado
mutant sem-conferir-sha-pin    '"$T/node.tar.xz" | sha256sum -c - >/dev/null 2>&1 ||'        '"$T/node.tar.xz" | cat >/dev/null 2>&1 ||'  c_pin_errado
mutant binario-sem-versao      '[ "$got" = "v$V" ] ||'                                        'true ||'                                  c_binario_mente
mutant sobrescreve-arquivo     'if [ -e "$l" ] || [ -L "$l" ]; then [ -L "$l" ] ||'          'if [ -e "$l" ] || [ -L "$l" ]; then true ||' c_arquivo
mutant dir-existente-vale      '[ "$("$D/bin/node" --version 2>/dev/null | head -n 1)" = "v$V" ] ||' 'true ||'                       c_dir_errado
mutant sem-idempotencia        'ok) report; exit 0 ;;'                                        'ok) ;;'                                   c_idem
mutant pin-sem-regex-versao    '[[ "$V" =~ $RE_VER ]] ||'                                     'true ||'                                  c_injecao
mutant ssh-rc-ignorado         'if [ $rc -ne 0 ] || ! printf'                                 'if false || ! printf'                     c_ssh_cai_depois
mutant sem-sentinela           '! printf '"'"'%s\n'"'"' "$out" | grep -qx '"'"'FIM'"'"'; then'  'false; then'                              c_sem_fim
mutant arquitetura-ignorada    '[ "$arch" = "Linux aarch64" ] ||'                             'true ||'                                  c_arch
mutant versao-nao-compara      'elif [ "$ver" = "v$V" ] && [ "$loc" = certo ]; then'          'elif [ "$loc" = certo ]; then'            c_versao_no_dir_certo
mutant local-nao-compara       'elif [ "$ver" = "v$V" ] && [ "$loc" = certo ]; then'          'elif [ "$ver" = "v$V" ]; then'            c_fora_do_pin
mutant temp-nao-limpa          'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null'"'"' EXIT'"${NL}"'curl' 'true'"'"' EXIT'"${NL}"'curl' c_adulterado
mutant conferencia-final-pulada 'probe
report; exit $?' 'STATE=ok; DETAIL="(mutante)"
report; exit $?' c_conferencia_final_nao_le
mutant ssh-255-do-install-ignorado '255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode $chk antes de tentar de novo" ;;' '255) ;;' c_install_ssh_cai_depois
mutant sem-fim-do-install-ignorado 'printf '"'"'%s\n'"'"' "$out" | grep -qx '"'"'FIM'"'"' || die 2' 'true || die 2' c_install_sem_fim
mutant arch-vazio-vira-arquitetura '[ -n "$arch" ] || {' 'true || {' c_arch_sem_linha
mutant home-literal-na-sonda 'H=$(cd "$HOME/.local" 2>/dev/null && pwd -P) || H=$HOME/.local'"${NL}"'echo "ARCH' 'H=$HOME/.local'"${NL}"'echo "ARCH' c_home_symlink
mutant usage-sai-2 'usage() { echo "uso: hetzner-nodejs.sh check|install [jsdom] [--pin ARQUIVO]" >&2; exit 64; }' 'usage() { echo "uso: hetzner-nodejs.sh check|install [jsdom] [--pin ARQUIVO]" >&2; exit 2; }' c_usage
# jsdom: cada mutante afrouxa UMA decisão do componente
mutant j-lock-local-nao-confere   '[ "$got" = "$JSHA" ] || die 4'                                       'true || die 4'                                                   c_j_lock_local
mutant j-lock-no-no-nao-confere   '"$ST/package-lock.json" | sha256sum -c - >/dev/null 2>&1 ||'        '"$ST/package-lock.json" | cat >/dev/null 2>&1 ||'                c_j_lock_no_no
mutant j-npm-roda-scripts         'npm ci --ignore-scripts --no-audit'                                  'npm ci --no-audit'                                               c_j_feliz
mutant j-registry-solto           '--registry=https://registry.npmjs.org/ --cache'                      '--cache'                                                         c_j_feliz
mutant j-cache-em-home            ' --cache "$T/npm-cache" )'                                           ' )'                                                              c_j_feliz
mutant j-npm-falha-ignorada       '|| { echo "RECUSO npm ci falhou: $(tail -n 1 "$T/npm.log")"; exit 5; }' '|| true'                                                   c_j_npm_falha
mutant j-versao-instalada-ignorada '[ "$got" = "$V" ] || { echo "RECUSO o jsdom instalado diz'          'true || { echo "RECUSO o jsdom instalado diz'                    c_j_versao_errada
mutant j-carga-nao-conferida      '|| { echo "RECUSO o jsdom $V não carrega com o node do pin"; exit 4; }' '|| true'                                                    c_j_nao_carrega
mutant j-sobrescreve-dir-comum    'if [ -e "$L" ] || [ -L "$L" ]; then [ -L "$L" ] || {'               'if [ -e "$L" ] || [ -L "$L" ]; then true || {'                   c_j_dir_comum
mutant j-dir-nao-e-diferente      'if [ "$kind" != link ]; then STATE=diferente;'                       'if false; then STATE=diferente;'                                 c_j_dir_comum
mutant j-dir-existente-vale       '[ "$(jv "$D")" = "$V" ] && NODE_PATH'                                'true && NODE_PATH'                                               c_j_dir_existe_errado
mutant j-dir-existente-sem-carga  '&& NODE_PATH="$D/node_modules" "$H/node/bin/node" -e "$LOAD" >/dev/null 2>&1 ||' '&& true ||'                                          c_j_quebrado
mutant j-idempotencia             'ok|nao-consegui|arquitetura) report; exit $? ;;'                     'nao-consegui|arquitetura) report; exit $? ;;'                    c_j_idem
mutant j-node-nao-exigido         '*) die 4 "recusado: o Node'                                          '*) : "recusado: o Node'                                          c_j_sem_node
mutant j-carga-nao-olhada         'elif [ "$ver" = ERRO ] || [ "$load" != ok ]; then'                   'elif [ "$ver" = ERRO ]; then'                                    c_j_quebrado
mutant j-lock-fora-da-identidade  'elif [ "$ver" = "$JV" ] && [ "$loc" = certo ]; then'                'elif [ "$ver" = "$JV" ]; then'                                   c_j_mesmo_jsdom_outro_lock
mutant j-versao-fora-da-identidade 'elif [ "$ver" = "$JV" ] && [ "$loc" = certo ]; then'               'elif [ "$loc" = certo ]; then'                                   c_j_versao_no_dir_certo
mutant j-sem-tratar-o-install     'after_install "$rc" "$out" "check jsdom"'                            'true'                                                            c_j_npm_falha
mutant j-conferencia-final-pulada 'probe_libs; report; exit $?'                                         'STATE=ok; DETAIL="(mutante)"; report; exit $?'                   c_j_conferencia_final
mutant j-versao-do-pin-sem-regex  '[[ "$JV" =~ $RE_VER ]] ||'                                          'true ||'                                                         c_j_injecao
mutant j-hash-do-pin-sem-regex    '[[ "$JSHA" =~ $RE_SHA ]] ||'                                         'true ||'                                                         c_j_hash_curto
mutant download-sem-rc         '--max-time 900 -o "$T/node.tar.xz" "https://nodejs.org/dist/v$V/$AD.tar.xz" ||' '--max-time 900 -o "$T/node.tar.xz" "https://nodejs.org/dist/v$V/$AD.tar.xz" || true ||' c_dl_falha

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
