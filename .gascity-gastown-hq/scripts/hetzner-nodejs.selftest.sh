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
STUBS="$T/stubs"; FIX="$T/fix"; FAKE_HOME="$T/home"; STUB_LOG="$T/stub.log"; PINF="$T/pin"; STUB_COUNT="$T/probe-count"
mkdir -p "$STUBS" "$FIX"
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
kind=probe; case "$*" in "bash -s -- "*" "*) kind=install ;; esac   # o install leva dois argumentos (versão e hash), a sonda um
if [ "$kind" = probe ]; then
  n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
  [ "$n" = "${STUB_SSH_FAIL_PROBE_N:-0}" ] && exit 255   # a N-ésima sonda cai (a 2a é a conferência final do install)
else
  [ -n "${STUB_SSH_RC_INSTALL:-}" ] && exit "$STUB_SSH_RC_INSTALL"   # cai ANTES de o install rodar
fi
out=$(HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash -c "$*"); rc=$?
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
chmod +x "$STUBS"/*
export STUB_LOG STUB_COUNT FAKE_HOME STUBS FIX MBP_SSH="$STUBS/ssh" HETZNER_NODE_HOST=fake HETZNER_NODEJS_PIN="$PINF"

# mkfix VERSÃO [VERSÃO QUE O BINÁRIO DIZ]: monta node-v<VERSÃO>-linux-arm64.tar.xz com bin/node falso; imprime o sha256
mkfix() {
  local v=$1 says=${2:-$1} d="$T/mk/node-v$1-linux-arm64"
  mkdir -p "$d/bin" && printf '#!/bin/sh\n[ "$1" = --version ] && echo v%s\n' "$says" > "$d/bin/node" && chmod +x "$d/bin/node" || return 1
  tar -cJf "$FIX/node-v$v-linux-arm64.tar.xz" -C "$T/mk" "node-v$v-linux-arm64" || return 1
  find "$T/mk" -mindepth 1 -delete; sha_of "$FIX/node-v$v-linux-arm64.tar.xz"
}
mkpin() { printf '# pin de teste\nNODE_VERSION=%s\nNODE_SHA256_LINUX_ARM64=%s\n' "$1" "$2" > "$PINF"; }
reset() { find "$FAKE_HOME" -mindepth 1 -delete 2>/dev/null; mkdir -p "$FAKE_HOME/.local/bin"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"; unset STUB_SSH_RC STUB_SSH_DROP_FIM STUB_SSH_RC_AFTER STUB_SSH_RC_INSTALL STUB_SSH_RC_AFTER_INSTALL STUB_SSH_DROP_FIM_INSTALL STUB_SSH_DROP_ARCH STUB_SSH_FAIL_PROBE_N STUB_CURL STUB_OS STUB_ARCH; }
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
CASES="c_vazio c_feliz c_idem c_adulterado c_pin_errado c_dl_falha c_arch c_pin_ausente c_injecao c_repetida c_ssh_cai c_ssh_cai_depois c_sem_fim c_arquivo c_upgrade c_dir_errado c_binario_mente c_quebrado c_fora_do_pin c_versao_no_dir_certo c_install_ssh_cai c_install_ssh_cai_depois c_install_sem_fim c_conferencia_final_nao_le c_arch_sem_linha c_home_symlink c_usage"
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
mutant sem-conferir-sha        '| sha256sum -c - >/dev/null 2>&1 ||'                         '| cat >/dev/null 2>&1 ||'                 c_adulterado
mutant sem-conferir-sha-pin    '| sha256sum -c - >/dev/null 2>&1 ||'                         '| cat >/dev/null 2>&1 ||'                 c_pin_errado
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
mutant temp-nao-limpa          'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' 'true'                              c_adulterado
mutant conferencia-final-pulada 'probe
report; exit $?' 'STATE=ok; DETAIL="(mutante)"
report; exit $?' c_conferencia_final_nao_le
mutant ssh-255-do-install-ignorado '255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;' '255) ;;' c_install_ssh_cai_depois
mutant sem-fim-do-install-ignorado 'printf '"'"'%s\n'"'"' "$out" | grep -qx '"'"'FIM'"'"' || die 2' 'true || die 2' c_install_sem_fim
mutant arch-vazio-vira-arquitetura '[ -n "$arch" ] || {' 'true || {' c_arch_sem_linha
mutant home-literal-na-sonda 'H=$(cd "$HOME/.local" 2>/dev/null && pwd -P) || H=$HOME/.local' 'H=$HOME/.local' c_home_symlink
mutant usage-sai-2 'usage() { echo "uso: hetzner-nodejs.sh check|install [--pin ARQUIVO]" >&2; exit 64; }' 'usage() { echo "uso: hetzner-nodejs.sh check|install [--pin ARQUIVO]" >&2; exit 2; }' c_usage
mutant download-sem-rc         '--max-time 900 -o "$T/node.tar.xz" "https://nodejs.org/dist/v$V/$AD.tar.xz" ||' '--max-time 900 -o "$T/node.tar.xz" "https://nodejs.org/dist/v$V/$AD.tar.xz" || true ||' c_dl_falha

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
