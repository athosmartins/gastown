#!/usr/bin/env bash
# hetzner-chromium.selftest.sh — hermético: ssh, uname, apt-get, dpkg, ldd e o python do venv-wa são stubs; o script REMOTO roda de verdade, num HOME temporário, com um "navegador" falso (um arquivo de bytes conhecidos). (ga-aptlug)
#
# Contents
#   Casos · Mutantes
#
# CASOS: check sem nada = ausente (rc 1) · install feliz (marcador, libpath, o navegador abre COM as bibliotecas, um argumento por pacote) · install de novo não baixa nada · sha256 do pin errado = rc 4, o navegador NUNCA é executado e não há marcador
#   · o marcador de um install anterior CAI no começo e uma recusa depois dele deixa o nó sem marcador · venv-wa com outro Playwright = rc 4 antes de baixar (e o marcador antigo fica) e "diferente" no check · apt-get e playwright install que falham = rc 5
#   · nenhum .deb = rc 5 · dpkg -x que falha, ldd que acusa biblioteca faltando, ldd que não roda, navegador que não abre ou que sai 0 sem CHROMIUM_OK = rc 4, sempre sem marcador · .deb e arquivos velhos de um install anterior saem
#   · nó x86_64 = rc 3 sem baixar · pin ausente, com injeção em DEB_PACKAGES ou com linha repetida = rc 2 SEM chamar o ssh · ssh que cai (antes e depois de responder), resposta sem FIM ou sem uma linha obrigatória = rc 2, nunca "ausente"
#   · "quebrado" (binário adulterado, ldd faltando, navegador que não abre, headless shell sumido, marcador ilegível) × "diferente" (marcador de outro pin, venv-wa com outro Playwright) × "ok".
# MUTANTES: cada um troca UM trecho do script por uma versão frouxa (python3, substring exata e única); o caso que deveria pegá-lo tem de falhar. Mutante que sobrevive = caso faltando.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/hetzner-chromium.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hchr-selftest.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P)
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
kind=probe; case "$*" in "bash -s -- "*) kind=install ;; esac   # o install leva argumentos (versão, hash, pacotes), a sonda nenhum
if [ "$kind" = probe ]; then
  n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
  [ "$n" = "${STUB_SSH_FAIL_PROBE_N:-0}" ] && exit 255   # a N-ésima sonda cai (a 2a é a conferência final do install)
else
  [ -n "${STUB_SSH_RC_INSTALL:-}" ] && exit "$STUB_SSH_RC_INSTALL"   # cai ANTES de o install rodar
fi
out=$(HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash -c "$*"); rc=$?
[ -n "${STUB_SSH_DROP_FIM:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = install ] && [ -n "${STUB_SSH_DROP_FIM_INSTALL:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = probe ] && [ -n "${STUB_SSH_DROP_LINE:-}" ] && out=$(printf '%s\n' "$out" | grep -v "^$STUB_SSH_DROP_LINE ")
printf '%s\n' "$out"
[ -n "${STUB_SSH_RC_AFTER:-}" ] && exit "$STUB_SSH_RC_AFTER"
[ "$kind" = install ] && [ -n "${STUB_SSH_RC_AFTER_INSTALL:-}" ] && exit "$STUB_SSH_RC_AFTER_INSTALL"   # cai DEPOIS de o install rodar
exit $rc
STUB
cat > "$STUBS/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -s) echo "${STUB_OS:-Linux}" ;; -m) echo "${STUB_ARCH:-aarch64}" ;; *) echo "${STUB_OS:-Linux}" ;; esac
STUB
cat > "$STUBS/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "APT:$*" >> "$STUB_LOG"
[ "${1:-}" = download ] || exit 100
case "${STUB_APT:-ok}" in fail) echo "E: Unable to locate package" >&2; exit 100 ;; vazio) exit 0 ;; esac
shift; for p in "$@"; do : > "${p}_1.0_arm64.deb"; done
STUB
cat > "$STUBS/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "DPKG:$*" >> "$STUB_LOG"
[ "${1:-}" = -x ] || exit 2
[ "${STUB_DPKG:-ok}" = fail ] && exit 2
p=$(basename "$2"); p=${p%%_*}; mkdir -p "$3/usr/lib/aarch64-linux-gnu"; : > "$3/usr/lib/aarch64-linux-gnu/$p.so.1"
STUB
cat > "$STUBS/ldd" <<'STUB'
#!/usr/bin/env bash
echo "LDD:LD=${LD_LIBRARY_PATH:-}" >> "$STUB_LOG"
case "${STUB_LDD:-ok}" in
  erro) echo "not a dynamic executable" >&2; exit 1 ;;
  falta) printf '\tlibnss3.so => not found\n\tlibnspr4.so => not found\n'; exit 0 ;;
esac
case ":${LD_LIBRARY_PATH:-}:" in *"/pw-chromium/env/root/"*) printf '\tlibnss3.so => /x/libnss3.so (0x1)\n' ;; *) printf '\tlibnss3.so => not found\n' ;; esac
STUB
command -v sha256sum >/dev/null 2>&1 || printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$STUBS/sha256sum"
# o python do venv-wa: responde a versão, "instala" o navegador falso e abre-o SÓ se as bibliotecas e a pasta dos navegadores chegaram no ambiente (o que o mbp-run.sh exporta)
cat > "$FIX/python" <<'STUB'
#!/usr/bin/env bash
echo "PY:$*" >> "$STUB_LOG"
case "$*" in
  *importlib.metadata*) echo "${STUB_PW_VER:-9.9.9}"; exit 0 ;;
  "-m playwright install chromium-headless-shell")
    [ "${STUB_PW_INSTALL:-ok}" = fail ] && { echo "net down" >&2; exit 1; }
    b="$PLAYWRIGHT_BROWSERS_PATH/chromium_headless_shell-9999/chrome-linux"; mkdir -p "$b" && printf '%s' "${STUB_BIN_BYTES:-navegador-bom}" > "$b/headless_shell" && chmod +x "$b/headless_shell"; exit 0 ;;
  *sync_playwright*)
    echo "LAUNCH:LD=${LD_LIBRARY_PATH:-} PW=${PLAYWRIGHT_BROWSERS_PATH:-}" >> "$STUB_LOG"
    [ "${STUB_LAUNCH:-ok}" = fail ] && { echo "Target page, context or browser has been closed" >&2; exit 1; }
    [ "${STUB_LAUNCH:-ok}" = mudo ] && exit 0
    case ":${LD_LIBRARY_PATH:-}:" in *"/pw-chromium/env/root/"*) ;; *) echo "error while loading shared libraries: libnss3.so" >&2; exit 1 ;; esac
    case "${PLAYWRIGHT_BROWSERS_PATH:-}" in */pw-chromium/env/browsers) ;; *) echo "Executable doesn't exist" >&2; exit 1 ;; esac
    echo CHROMIUM_OK; exit 0 ;;
esac
exit 64
STUB
chmod +x "$STUBS"/* "$FIX/python"
export STUB_LOG STUB_COUNT FAKE_HOME STUBS FIX MBP_SSH="$STUBS/ssh" HETZNER_NODE_HOST=fake HETZNER_CHROMIUM_PIN="$PINF"

printf 'navegador-bom' > "$FIX/bom"; printf 'navegador-adulterado' > "$FIX/mau"
SHAB=$(sha_of "$FIX/bom"); SHAM=$(sha_of "$FIX/mau")
DEBS="libaaa libbbb libccc"
mkpin() { printf '# pin de teste\nPLAYWRIGHT_VERSION=%s\nHEADLESS_SHELL_SHA256_LINUX_ARM64=%s\nDEB_PACKAGES=%s\n' "${1:-9.9.9}" "${2:-$SHAB}" "${3:-$DEBS}" > "$PINF"; }
D="$FAKE_HOME/gt-remote/pw-chromium/env"
reset() { find "$FAKE_HOME" -mindepth 1 -delete 2>/dev/null; mkdir -p "$FAKE_HOME/gt-remote/venv-wa/bin"; cp "$FIX/python" "$FAKE_HOME/gt-remote/venv-wa/bin/python"; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  unset STUB_SSH_RC STUB_SSH_DROP_FIM STUB_SSH_RC_AFTER STUB_SSH_RC_INSTALL STUB_SSH_RC_AFTER_INSTALL STUB_SSH_DROP_FIM_INSTALL STUB_SSH_DROP_LINE STUB_SSH_FAIL_PROBE_N STUB_OS STUB_ARCH STUB_APT STUB_DPKG STUB_LDD STUB_LAUNCH STUB_PW_VER STUB_PW_INSTALL STUB_BIN_BYTES; mkpin; }
run() { ( cd "$T" && bash "${SCRIPT:-$S}" "$@" > "$T/out" 2>"$T/err" ); echo $?; }   # cwd = o temporário: o mutante sem regex EXECUTA a injeção, e o que ela criar não pode cair no repositório
installed() { reset; local rc; rc=$(run install); [ "$rc" = 0 ] || echo "(setup: install saiu $rc)"; : > "$STUB_LOG"; }
isready() { [ -e "$D/ready" ]; }
noready() { isready && bad "$1: o marcador ready NÃO pode existir" || ok "$1: sem marcador"; }
stubset() { export "$@"; }   # stubset VAR=valor

c_vazio() { reset; local rc; rc=$(run check); eq "check sem nada: rc 1" 1 "$rc"; has "…diz ausente (não 'não consegui')" "$T/out" '^CHROMIUM ausente'; }
c_feliz() { reset; local rc; rc=$(run install); eq "install feliz: rc 0" 0 "$rc"; isready && ok "…marcador ready gravado" || bad "…sem marcador ready"
  has "…marcador com a versão do pin" "$D/ready" '^PLAYWRIGHT_VERSION=9\.9\.9$'; has "…marcador com o sha do pin" "$D/ready" "^HEADLESS_SHELL_SHA256=$SHAB\$"
  has "…libpath.txt aponta para as bibliotecas extraídas" "$D/libpath.txt" '/gt-remote/pw-chromium/env/root/usr/lib/aarch64-linux-gnu'
  has "…um argumento por pacote no apt-get download" "$STUB_LOG" 'APT:download libaaa libbbb libccc$'; has "…o navegador abriu COM as bibliotecas no ambiente" "$STUB_LOG" 'LAUNCH:LD=.*/pw-chromium/env/root/.* PW=.*/pw-chromium/env/browsers$'
  has "…baixou só o headless shell" "$STUB_LOG" 'PY:-m playwright install chromium-headless-shell$'; has "…a saída diz ok" "$T/out" '^CHROMIUM ok'
  rc=$(run check); eq "check depois: rc 0" 0 "$rc"; has "…diz ok" "$T/out" '^CHROMIUM ok'; }
c_idem() { installed; local rc; rc=$(run install); eq "install de novo: rc 0" 0 "$rc"; hasnt "…não baixa pacote" "$STUB_LOG" 'APT:'; hasnt "…não roda playwright install" "$STUB_LOG" 'PY:-m playwright install'; }
c_sha_errado() { reset; mkpin 9.9.9 "$SHAM"; local rc; rc=$(run install); eq "sha256 do pin errado: rc 4" 4 "$rc"; has "…diz que o sha256 não confere" "$T/out" 'sha256'; noready "…"
  hasnt "…o navegador não verificado NUNCA foi executado (ldd)" "$STUB_LOG" 'LDD:'; hasnt "…nem aberto" "$STUB_LOG" 'LAUNCH:'; hasnt "…nem baixou pacote" "$STUB_LOG" 'APT:'; }
c_marcador_cai() { installed; stubset STUB_LAUNCH=fail; local rc; rc=$(run install); eq "install com o marcador antigo e o navegador que não abre: rc 4" 4 "$rc"; noready "…o marcador antigo caiu e não voltou"
  has "…a recusa diz que o navegador não abriu" "$T/out" 'não abriu'; has "…e que os e2e continuam pulando" "$T/out" 'sem marcador'; }
c_venv_outro() { installed; stubset STUB_PW_VER=9.9.8; local rc; rc=$(run check); eq "venv-wa com outro Playwright: check rc 1" 1 "$rc"; has "…diz diferente" "$T/out" '^CHROMIUM diferente'; has "…e nomeia as duas versões" "$T/out" "9\.9\.8.*9\.9\.9"
  rc=$(run install); eq "install com o venv-wa de outra versão: rc 4" 4 "$rc"; hasnt "…recusou ANTES de baixar" "$STUB_LOG" 'PY:-m playwright install'; isready && ok "…o marcador antigo fica (a recusa veio antes de mexer)" || bad "…o marcador antigo sumiu"; }
c_apt_falha() { reset; stubset STUB_APT=fail; local rc; rc=$(run install); eq "apt-get download falha: rc 5" 5 "$rc"; has "…a recusa nomeia o apt-get" "$T/out" 'apt-get download falhou'; noready "…"; }
c_apt_vazio() { reset; stubset STUB_APT=vazio; local rc; rc=$(run install); eq "nenhum .deb baixado: rc 5" 5 "$rc"; has "…diz nenhum .deb" "$T/out" 'nenhum \.deb'; noready "…"; }
c_pw_falha() { reset; stubset STUB_PW_INSTALL=fail; local rc; rc=$(run install); eq "playwright install falha: rc 5" 5 "$rc"; noready "…"; hasnt "…não chegou ao apt" "$STUB_LOG" 'APT:'; }
c_dpkg_falha() { reset; stubset STUB_DPKG=fail; local rc; rc=$(run install); eq "dpkg -x falha: rc 4" 4 "$rc"; has "…nomeia o dpkg" "$T/out" 'dpkg -x falhou'; noready "…"; }
c_ldd_falta() { reset; stubset STUB_LDD=falta; local rc; rc=$(run install); eq "ldd acusa biblioteca faltando: rc 4" 4 "$rc"; has "…diz quantas" "$T/out" '2 biblioteca'; noready "…"; hasnt "…nem tentou abrir o navegador" "$STUB_LOG" 'LAUNCH:'; }
c_ldd_rc() { reset; stubset STUB_LDD=erro; local rc; rc=$(run install); eq "ldd que não roda: rc 4 (não vira 'zero faltando')" 4 "$rc"; has "…diz que o ldd não rodou" "$T/out" 'ldd não rodou'; noready "…"; }
c_launch_falha() { reset; stubset STUB_LAUNCH=fail; local rc; rc=$(run install); eq "navegador que não abre: rc 4" 4 "$rc"; has "…cita o erro do navegador" "$T/out" 'Target page'; noready "…"; }
c_launch_mudo() { reset; stubset STUB_LAUNCH=mudo; local rc; rc=$(run install); eq "navegador que sai 0 sem CHROMIUM_OK: rc 4" 4 "$rc"; has "…diz que faltou CHROMIUM_OK" "$T/out" 'CHROMIUM_OK'; noready "…"; }
c_limpa_antigos() { reset; mkdir -p "$D/debs" "$D/root/usr/lib"; : > "$D/debs/velho_0.9_arm64.deb"; : > "$D/root/usr/lib/restolho.so.1"; local rc; rc=$(run install); eq "install sobre um ambiente velho: rc 0" 0 "$rc"
  [ -e "$D/debs/velho_0.9_arm64.deb" ] && bad "…o .deb velho continua em debs/" || ok "…o .deb velho saiu"; [ -e "$D/root/usr/lib/restolho.so.1" ] && bad "…o arquivo velho continua em root/" || ok "…o arquivo velho saiu"; }
c_arch() { reset; stubset STUB_ARCH=x86_64; local rc; rc=$(run check); eq "check em x86_64: rc 3" 3 "$rc"; rc=$(run install); eq "install em x86_64: rc 3" 3 "$rc"; hasnt "…não baixa nada" "$STUB_LOG" 'PY:-m playwright install'; }
c_pin_ausente() { reset; local rc; rc=$(run check --pin "$T/nao-existe"); eq "pin ausente: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_injecao() { reset; printf 'PLAYWRIGHT_VERSION=9.9.9\nHEADLESS_SHELL_SHA256_LINUX_ARM64=%s\nDEB_PACKAGES=libnss3; touch %s/pwned\n' "$SHAB" "$T" > "$PINF"; local rc; rc=$(run install); eq "pacote com injeção: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; [ -e "$T/pwned" ] && bad "…o comando injetado rodou" || ok "…nada injetado rodou"; }
c_repetida() { reset; printf 'PLAYWRIGHT_VERSION=9.9.9\nPLAYWRIGHT_VERSION=9.9.8\nHEADLESS_SHELL_SHA256_LINUX_ARM64=%s\nDEB_PACKAGES=libnss3\n' "$SHAB" > "$PINF"; local rc; rc=$(run check); eq "PLAYWRIGHT_VERSION repetida: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_ssh_cai() { reset; stubset STUB_SSH_RC=255; local rc; rc=$(run check); eq "ssh caiu: rc 2" 2 "$rc"; has "…NAO-CONSEGUI, não 'ausente'" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz ausente" "$T/out" '^CHROMIUM ausente'; }
c_ssh_cai_depois() { reset; stubset STUB_SSH_RC_AFTER=255; local rc; rc=$(run check); eq "ssh caiu depois de responder: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_sem_fim() { reset; stubset STUB_SSH_DROP_FIM=1; local rc; rc=$(run check); eq "resposta sem a sentinela FIM: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_arch_sem_linha() { reset; stubset STUB_SSH_DROP_LINE=ARCH; local rc; rc=$(run check); eq "resposta com FIM mas sem a linha ARCH: rc 2 (não 3)" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz 'arquitetura'" "$T/out" '^CHROMIUM arquitetura'; }
c_sem_mark() { reset; stubset STUB_SSH_DROP_LINE=MARK; local rc; rc=$(run check); eq "resposta sem a linha MARK: rc 2 (não 'ausente')" 2 "$rc"; hasnt "…não diz ausente" "$T/out" '^CHROMIUM ausente'; }
c_sem_bin() { installed; stubset STUB_SSH_DROP_LINE=BIN; local rc; rc=$(run check); eq "marcador presente mas resposta sem a linha BIN: rc 2 (não 'ok')" 2 "$rc"; hasnt "…não diz ok" "$T/out" '^CHROMIUM ok'; }
c_quebrado_bin() { installed; cp "$FIX/mau" "$D/browsers/chromium_headless_shell-9999/chrome-linux/headless_shell"; local rc; rc=$(run check); eq "headless shell adulterado depois do install: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^CHROMIUM quebrado'; has "…e o sha256" "$T/out" 'sha256'
  rc=$(run install); eq "install conserta: rc 0" 0 "$rc"; rc=$(run check); eq "…e o check seguinte diz ok" 0 "$rc"; }
c_quebrado_ldd() { installed; stubset STUB_LDD=falta; local rc; rc=$(run check); eq "ldd acusa faltando depois do install: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^CHROMIUM quebrado'; has "…e o ldd" "$T/out" 'ldd'; }
c_quebrado_launch() { installed; stubset STUB_LAUNCH=fail; local rc; rc=$(run check); eq "navegador que não abre depois do install: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^CHROMIUM quebrado'; has "…e que não abriu" "$T/out" 'não abriu'; }
c_sumiu() { installed; find "$D/browsers" -mindepth 1 -delete; local rc; rc=$(run check); eq "marcador sem o headless shell: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^CHROMIUM quebrado'; has "…e que o shell sumiu" "$T/out" 'sumiu'; }
c_marcador_ilegivel() { installed; printf 'lixo\n' > "$D/ready"; local rc; rc=$(run check); eq "marcador sem as chaves: check rc 1" 1 "$rc"; has "…diz quebrado (não diferente, não ok)" "$T/out" '^CHROMIUM quebrado'; }
c_marcador_outro() { installed; printf 'PLAYWRIGHT_VERSION=9.9.9\nHEADLESS_SHELL_SHA256=%s\n' "$SHAM" > "$D/ready"; local rc; rc=$(run check); eq "marcador de outro hash: check rc 1" 1 "$rc"; has "…diz diferente (não ok)" "$T/out" '^CHROMIUM diferente'; }
c_install_ssh_cai() { reset; stubset STUB_SSH_RC_INSTALL=255; local rc; rc=$(run install); eq "install: ssh cai na chamada do install: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; noready "…"; }
c_install_ssh_cai_depois() { reset; stubset STUB_SSH_RC_AFTER_INSTALL=255; local rc; rc=$(run install); eq "install: ssh cai DEPOIS de o install rodar (saída completa, rc 255): rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_install_sem_fim() { reset; stubset STUB_SSH_DROP_FIM_INSTALL=1; local rc; rc=$(run install); eq "install: resposta do install sem a sentinela FIM: rc 2" 2 "$rc"; has "…diz que faltou a sentinela" "$T/out" 'sentinela FIM'; }
c_conferencia_final_nao_le() { reset; stubset STUB_SSH_FAIL_PROBE_N=2; local rc; rc=$(run install); eq "install ok mas a sonda FINAL não consegue ler: rc 2 (não 1)" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_usage() { reset; local rc; rc=$(run); eq "sem subcomando: rc 64 (uso errado), não 2" 64 "$rc"; rc=$(run install --pin); eq "--pin sem argumento: rc 64" 64 "$rc"; }
CASES="c_vazio c_feliz c_idem c_sha_errado c_marcador_cai c_venv_outro c_apt_falha c_apt_vazio c_pw_falha c_dpkg_falha c_ldd_falta c_ldd_rc c_launch_falha c_launch_mudo c_limpa_antigos c_arch c_pin_ausente c_injecao c_repetida c_ssh_cai c_ssh_cai_depois c_sem_fim c_arch_sem_linha c_sem_mark c_sem_bin c_quebrado_bin c_quebrado_ldd c_quebrado_launch c_sumiu c_marcador_ilegivel c_marcador_outro c_install_ssh_cai c_install_ssh_cai_depois c_install_sem_fim c_conferencia_final_nao_le c_usage"
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
mutant sem-conferir-sha        '| sha256sum -c - >/dev/null 2>&1 ||'                      '| cat >/dev/null 2>&1 ||'                  c_sha_errado
mutant marcador-nao-cai        'rm -f "$D/ready" "$D/ready.tmp"'                            'true'                                      c_marcador_cai
mutant ldd-faltando-ignorado   '[ "$miss" = 0 ] ||'                                         'true ||'                                   c_ldd_falta
mutant ldd-rc-ignorado         '"$bin" 2>&1) || { echo "RECUSO o ldd não rodou no navegador"; exit 4; }' '"$bin" 2>&1) || true'      c_ldd_rc
mutant sem-chromium-ok         'grep -qx CHROMIUM_OK || { echo "RECUSO o teste de abrir o navegador não imprimiu CHROMIUM_OK"; exit 4; }' 'true'  c_launch_mudo
mutant apt-rc-ignorado         '|| { echo "RECUSO apt-get download falhou"; exit 5; }'      '|| true'                                   c_apt_falha
mutant sem-nenhum-deb          '[ "$n" -gt 0 ] ||'                                          'true ||'                                   c_apt_vazio
mutant dpkg-rc-ignorado        'dpkg -x "$f" "$D/root" || { echo "RECUSO dpkg -x falhou em $f"; exit 4; }' 'dpkg -x "$f" "$D/root" || true' c_dpkg_falha
mutant venv-nao-compara-install '[ "$got" = "$PW" ] ||'                                     'true ||'                                   c_venv_outro
mutant venv-nao-compara-check  'if [ "$vver" != "$PW" ]; then STATE=diferente'              'if false; then STATE=diferente'            c_venv_outro
mutant marcador-nao-compara    'if [ "$mver" != "$PW" ] || [ "$msha" != "$SHA" ]; then'     'if false; then'                            c_marcador_outro
mutant marcador-ilegivel-vale  'if [ "$mver" = ilegivel ] || [ "$msha" = ilegivel ]; then'  'if false; then'                            c_marcador_ilegivel
mutant bin-nao-compara         'elif [ "$bsha" != "$SHA" ]; then'                           'elif false; then'                          c_quebrado_bin
mutant ldd-nao-compara         'elif [ "$lddn" != 0 ]; then'                                'elif false; then'                          c_quebrado_ldd
mutant launch-nao-compara      'elif [ "$lnch" != ok ]; then'                               'elif false; then'                          c_quebrado_launch
mutant shell-sumido-vale       'if [ "$bsha" = ausente ]; then STATE=quebrado'              'if false; then STATE=quebrado'             c_sumiu
mutant arquitetura-ignorada    '[ "$arch" = "Linux aarch64" ] ||'                           'true ||'                                   c_arch
mutant arch-vazio-vira-arquitetura '[ -n "$arch" ] || {'                                    'true || {'                                 c_arch_sem_linha
mutant mark-vazio-vira-ausente '[ -n "$vver" ] && [ -n "$mark" ] ||'                        'true ||'                                   c_sem_mark
mutant bin-vazio-vira-ok       '[ -n "$bsha" ] && [ -n "$lddn" ] && [ -n "$lnch" ] ||'      'true ||'                                   c_sem_bin
mutant ssh-rc-ignorado         'if [ $rc -ne 0 ] || ! printf'                               'if false || ! printf'                      c_ssh_cai_depois
mutant sem-sentinela           "|| ! printf '%s\\n' \"\$out\" | grep -qx 'FIM'; then STATE=nao-consegui" '; then STATE=nao-consegui' c_sem_fim
mutant sem-idempotencia        'ok) report; exit 0 ;;'                                      'ok) ;;'                                    c_idem
mutant pin-sem-regex-pacotes   '[[ "$DEBS" =~ $RE_DEBS ]] ||'                               'true ||'                                   c_injecao
mutant antigos-ficam           'find "$D/debs" "$D/root" -mindepth 1 -delete'               'true'                                      c_limpa_antigos
mutant conferencia-final-pulada 'probe
report; exit $?' 'STATE=ok; DETAIL="(mutante)"
report; exit $?' c_conferencia_final_nao_le
mutant ssh-255-do-install-ignorado '255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;' '255) ;;' c_install_ssh_cai_depois
mutant sem-fim-do-install-ignorado "printf '%s\\n' \"\$out\" | grep -qx 'FIM' || die 2" 'true || die 2' c_install_sem_fim
mutant usage-sai-2             'usage() { echo "uso: hetzner-chromium.sh check|install [--pin ARQUIVO]" >&2; exit 64; }' 'usage() { echo "uso: hetzner-chromium.sh check|install [--pin ARQUIVO]" >&2; exit 2; }' c_usage

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
