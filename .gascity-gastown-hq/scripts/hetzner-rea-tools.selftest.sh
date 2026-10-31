#!/usr/bin/env bash
# hetzner-rea-tools.selftest.sh — hermético: ssh, curl, uname e o npm do nó são stubs; o script REMOTO roda de verdade, num HOME temporário, com um JDK falso (um script que responde -version, --list-modules e as chamadas dos wrappers), um npm falso que monta um rea-agents falso e artefatos falsos de bytes conhecidos. O node é o do PATH (precisa existir). (ga-kfxzpt, ga-03w2fck)
#
# Contents
#   Casos · Mutantes
#
# CASOS: check sem nada = ausente (rc 1) · install feliz (marcador com as 5 versões e TOOLS, incluindo o rea, links, wrappers, as 4 URLs montadas do pin, check depois = ok) · install de novo não baixa nada · sha256 errado de CADA artefato = rc 4, nada é aberto e não há
#   marcador · sha do jar de dentro do zip do jadx errado, zip sem o jar, jar do REA sem uma das classes, tar sem bin/java, java de outra versão, JDK sem jdk.compiler = rc 4 · jadx/apktool que dizem outra versão = rc 4 · curl que falha = rc 5 · o marcador de um install anterior
#   CAI no começo e uma recusa depois dele deixa o nó sem marcador, sem a pasta temporária · wrappers (heap padrão, JADX_HEAP_MB/APKTOOL_HEAP_MB, valor lixo volta ao padrão) · nó x86_64 = rc 3 sem baixar · pin ausente, com chave repetida ou fora do formato = rc 2 SEM chamar
#   o ssh · ssh que cai (antes e depois de responder), resposta sem FIM ou sem uma linha obrigatória = rc 2, nunca "ausente" · "quebrado" (jar adulterado, java sumido, sem jdk.compiler, jar do REA sem classe, jadx que diz outra versão, marcador ilegível) × "diferente" (marcador de outro pin) × "ok".
# O REA (ga-03w2fck): lock com sha256 diferente do pin, ou rea-agents do lock com outro integrity = rc 4 SEM chamar o install (mini); lock adulterado em trânsito = rc 4 (nó); sem Node no nó = rc 4; npm ci que falha = rc 5; rea que diz outra versão (antes e depois de ir para a pasta final) = rc 4;
#   $D/rea que é diretório comum = rc 4; marcador antigo (sem REA_VERSION) = quebrado; rea sumido, versão errada ou lock adulterado depois do install = quebrado; o wrapper bin/rea passa os argumentos ao rea pelo node do nó.
# MUTANTES: cada um troca UM trecho do script por uma versão frouxa (python3, substring exata e única); o caso que deveria pegá-lo tem de falhar. Mutante que sobrevive = caso faltando.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/hetzner-rea-tools.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hrt-selftest.XXXXXX") || exit 2; T=$(cd "$T" && pwd -P)
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
kind=probe; case "$*" in "bash -s -- "*) kind=install ;; esac   # o install leva argumentos (versões e hashes), a sonda nenhum
if [ "$kind" = probe ]; then
  n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
  [ "$n" = "${STUB_SSH_FAIL_PROBE_N:-0}" ] && exit 255   # a N-ésima sonda cai (a 2a é a conferência final do install)
else
  [ -n "${STUB_SSH_RC_INSTALL:-}" ] && exit "$STUB_SSH_RC_INSTALL"   # cai ANTES de o install rodar
fi
if [ "$kind" = install ] && [ -n "${STUB_CORRUPT_LOCK:-}" ]; then   # o lock chega ao nó com 3 bytes a mais (decodifica, mas o sha256 muda): simula adulteração em trânsito
  out=$(sed "s/^RLOCKB64='/RLOCKB64='QUJD/" | HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash -c "$*"); rc=$?
else out=$(HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash -c "$*"); rc=$?; fi
[ -n "${STUB_SSH_DROP_FIM:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = install ] && [ -n "${STUB_SSH_DROP_FIM_INSTALL:-}" ] && out=$(printf '%s\n' "$out" | grep -v '^FIM$')
[ "$kind" = probe ] && [ -n "${STUB_SSH_DROP_LINE:-}" ] && out=$(printf '%s\n' "$out" | grep -v "^$STUB_SSH_DROP_LINE ")
[ "$kind" = probe ] && [ -n "${STUB_SSH_SHORT_MARK:-}" ] && out=$(printf '%s\n' "$out" | sed 's/^\(MARK [^ ]* [^ ]* [^ ]* [^ ]*\) .*/\1/')   # a linha MARK chega SEM o 5º campo (resposta truncada)
printf '%s\n' "$out"
[ -n "${STUB_SSH_RC_AFTER:-}" ] && exit "$STUB_SSH_RC_AFTER"
[ "$kind" = install ] && [ -n "${STUB_SSH_RC_AFTER_INSTALL:-}" ] && exit "$STUB_SSH_RC_AFTER_INSTALL"   # cai DEPOIS de o install rodar
exit $rc
STUB
cat > "$STUBS/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -s) echo "${STUB_OS:-Linux}" ;; -m) echo "${STUB_ARCH:-aarch64}" ;; *) echo "${STUB_OS:-Linux}" ;; esac
STUB
# curl falso: registra a URL e entrega o arquivo do artefato pelo NOME no fim da URL; STUB_BAD=<jdk|zip|apk|mcp> entrega bytes errados naquele artefato; STUB_CURL_FAIL=1 falha
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
out=; url=; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "CURL:$url" >> "$STUB_LOG"
[ "${STUB_CURL_FAIL:-0}" = 1 ] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
case "$url" in
  */OpenJDK*.tar.gz) f=${STUB_JDK_FILE:-jdk.tgz}; k=jdk ;; */jadx-*.zip) f=${STUB_ZIP_FILE:-jadx.zip}; k=zip ;; */apktool-cli-*.jar) f=apktool.jar; k=apk ;; */jadx-headless-mcp-*-all.jar) f=${STUB_MCP_FILE:-mcp.jar}; k=mcp ;;
  *) echo "curl: url inesperada $url" >&2; exit 22 ;;
esac
[ "${STUB_BAD:-}" = "$k" ] && f=mau
cp "$FIX/$f" "$out"
STUB
command -v sha256sum >/dev/null 2>&1 || printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' > "$STUBS/sha256sum"
# o java falso: responde as três perguntas do install/check e as chamadas dos wrappers (a classe jadx.cli.JadxCLI e o -jar do apktool); registra os argumentos
cat > "$FIX/java" <<'STUB'
#!/usr/bin/env bash
echo "JAVA:$*" >> "$STUB_LOG"
case "$*" in
  "-version") printf 'openjdk version "9.9.9" 2025-01-01\nOpenJDK Runtime Environment Temurin-%s (build 9.9.9+1)\n' "${STUB_JDK_VER:-9.9.9+1}" >&2 ;;
  "--list-modules") echo "java.base@9.9.9"; [ "${STUB_COMPILER:-1}" = 1 ] && echo "jdk.compiler@9.9.9"; exit 0 ;;
  *JadxCLI*) echo "${STUB_JADX_VER:-8.8.8}" ;;
  *-jar*) echo "${STUB_APK_VER:-7.7.7}" ;;
esac
exit 0
STUB
chmod +x "$STUBS"/* "$FIX/java"
REAL_NODE=$(command -v node) || { echo "FAIL: o selftest precisa de um node no PATH"; exit 2; }
RLIB="$T/rea-libs"; mkdir -p "$RLIB"; RINTEG="sha512-$(printf 'A%.0s' $(seq 1 86))=="
printf '{\n  "name": "fake-rea-libs",\n  "private": true,\n  "dependencies": { "rea-agents": "5.5.5" }\n}\n' > "$RLIB/package.json"
printf '{\n  "lockfileVersion": 3,\n  "packages": {\n    "": { "dependencies": { "rea-agents": "5.5.5" } },\n    "node_modules/rea-agents": { "version": "5.5.5", "integrity": "%s" }\n  }\n}\n' "$RINTEG" > "$RLIB/package-lock.json"
export STUB_LOG STUB_COUNT FAKE_HOME STUBS FIX REAL_NODE MBP_SSH="$STUBS/ssh" HETZNER_NODE_HOST=fake HETZNER_REA_TOOLS_PIN="$PINF" HETZNER_REA_LIBS="$RLIB"

# artefatos falsos: tar do JDK (com e sem bin/java), zip do jadx (com e sem o jar), jar do apktool, jar do REA (com as 5 classes e sem uma), e bytes errados
mkdir -p "$FIX/jdkroot/jdk-9.9.9+1/bin" "$FIX/nojava/jdk-9.9.9+1"; cp "$FIX/java" "$FIX/jdkroot/jdk-9.9.9+1/bin/java"; : > "$FIX/nojava/jdk-9.9.9+1/README"
( cd "$FIX/jdkroot" && tar -czf "$FIX/jdk.tgz" jdk-9.9.9+1 ) && ( cd "$FIX/nojava" && tar -czf "$FIX/jdk-nojava.tgz" jdk-9.9.9+1 )
printf 'jadx-jar-bom' > "$FIX/jadx-all.jar"; printf 'apktool-bom' > "$FIX/apktool.jar"; printf 'adulterado' > "$FIX/mau"
python3 -I - "$FIX" <<'PY'
import sys, zipfile
f = sys.argv[1]
classes = ["com/atxx/jhmcp/JadxSession.class", "com/atxx/jhmcp/SessionHolder.class", "jadx/api/JadxDecompiler.class", "com/google/gson/Gson.class", "io/modelcontextprotocol/kotlin/sdk/server/Server.class"]
with zipfile.ZipFile(f + "/jadx.zip", "w") as z:
    z.writestr("bin/jadx", "x"); z.write(f + "/jadx-all.jar", "lib/jadx-8.8.8-all.jar")
with zipfile.ZipFile(f + "/jadx-nomember.zip", "w") as z:
    z.writestr("bin/jadx", "x")
with zipfile.ZipFile(f + "/mcp.jar", "w") as z:
    for c in classes: z.writestr(c, "")
with zipfile.ZipFile(f + "/mcp-extra.jar", "w") as z:
    for c in classes: z.writestr(c, "")
    z.writestr("extra.txt", "bytes a mais")
with zipfile.ZipFile(f + "/mcp-bad.jar", "w") as z:
    for c in classes[:-1]: z.writestr(c, "")
PY
H_JDK=$(sha_of "$FIX/jdk.tgz"); H_ZIP=$(sha_of "$FIX/jadx.zip"); H_JAR=$(sha_of "$FIX/jadx-all.jar"); H_APK=$(sha_of "$FIX/apktool.jar"); H_MCP=$(sha_of "$FIX/mcp.jar")
H_RLOCK=$(sha_of "$RLIB/package-lock.json"); H_NOJAVA=$(sha_of "$FIX/jdk-nojava.tgz"); H_NOMEM=$(sha_of "$FIX/jadx-nomember.zip"); H_MCPBAD=$(sha_of "$FIX/mcp-bad.jar"); H_MAU=$(sha_of "$FIX/mau")
mkpin() { printf '# pin de teste\nJDK_VERSION=9.9.9+1\nJDK_SHA256_LINUX_ARM64=%s\nJADX_VERSION=8.8.8\nJADX_ZIP_SHA256=%s\nJADX_JAR_SHA256=%s\nAPKTOOL_VERSION=7.7.7\nAPKTOOL_JAR_SHA256=%s\nJADX_MCP_VERSION=6.6.6\nJADX_MCP_JAR_SHA256=%s\nREA_VERSION=5.5.5\nREA_INTEGRITY=%s\nREA_LOCK_SHA256=%s\n' "$H_JDK" "$H_ZIP" "$H_JAR" "$H_APK" "$H_MCP" "$RINTEG" "$H_RLOCK" > "$PINF"
  local kv; for kv in "$@"; do sed "s|^${kv%%=*}=.*|$kv|" "$PINF" > "$PINF.n" && mv "$PINF.n" "$PINF"; done; }   # mkpin CHAVE=valor...: troca linhas do pin padrão
D="$FAKE_HOME/.local/share/rea-tools"
mkrea() { mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.local/node/bin"; ln -sf "$REAL_NODE" "$FAKE_HOME/.local/bin/node"
  cat > "$FAKE_HOME/.local/node/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "NPM:$*" >> "$STUB_LOG"
[ "${STUB_NPM_FAIL:-0}" = 1 ] && { echo "npm ERR! network" >&2; exit 1; }
[ "$1" = ci ] || exit 2
mkdir -p node_modules/rea-agents/scripts
printf '{"name":"rea-agents","version":"%s"}\n' "${STUB_REA_VER:-5.5.5}" > node_modules/rea-agents/package.json
cat > node_modules/rea-agents/scripts/rea.mjs <<'JS'
const v = process.env.STUB_REA_VER || "5.5.5";
const bad = process.env.STUB_REA_BAD_FINAL && !process.argv[1].includes(".install.");
if (process.argv[2] === "--version") console.log(bad ? "0.0.0" : v);
else console.log("rea-args:" + process.argv.slice(2).join(" "));
JS
NPM
  chmod +x "$FAKE_HOME/.local/node/bin/npm"; }
reset() { find "$FAKE_HOME" -mindepth 1 -delete 2>/dev/null; mkdir -p "$FAKE_HOME"; mkrea; : > "$STUB_LOG"; rm -f "$STUB_COUNT"
  unset STUB_SSH_SHORT_MARK STUB_NPM_FAIL STUB_REA_VER STUB_REA_BAD_FINAL STUB_CORRUPT_LOCK STUB_SSH_RC STUB_SSH_DROP_FIM STUB_SSH_RC_AFTER STUB_SSH_RC_INSTALL STUB_SSH_RC_AFTER_INSTALL STUB_SSH_DROP_FIM_INSTALL STUB_SSH_DROP_LINE STUB_SSH_FAIL_PROBE_N STUB_OS STUB_ARCH STUB_BAD STUB_CURL_FAIL STUB_JDK_FILE STUB_ZIP_FILE STUB_MCP_FILE STUB_JDK_VER STUB_COMPILER STUB_JADX_VER STUB_APK_VER; mkpin; }
run() { ( cd "$T" && bash "${SCRIPT:-$S}" "$@" > "$T/out" 2>"$T/err" ); echo $?; }   # cwd = o temporário: o mutante sem regex EXECUTA a injeção, e o que ela criar não pode cair no repositório
installed() { reset; local rc; rc=$(run install); [ "$rc" = 0 ] || echo "(setup: install saiu $rc)"; : > "$STUB_LOG"; }
isready() { [ -e "$D/ready" ]; }
noready() { isready && bad "$1: o marcador ready NÃO pode existir" || ok "$1: sem marcador"; }
stubset() { export "$@"; }   # stubset VAR=valor
noleft() { n=$((n+1)); if find "$D" -maxdepth 1 -name '.install.*' 2>/dev/null | grep -q .; then echo "FAIL $1: a pasta temporária .install.* ficou"; fails=$((fails+1)); else echo "ok   $1: sem pasta temporária"; fi; }

c_vazio() { reset; local rc; rc=$(run check); eq "check sem nada: rc 1" 1 "$rc"; has "…diz ausente (não 'não consegui')" "$T/out" '^REATOOLS ausente'; }
c_feliz() { reset; local rc; rc=$(run install); eq "install feliz: rc 0" 0 "$rc"; isready && ok "…marcador ready gravado" || bad "…sem marcador ready"
  has "…marcador com as 5 versões" "$D/ready" '^JDK_VERSION=9\.9\.9\+1$'; has "…" "$D/ready" '^JADX_VERSION=8\.8\.8$'; has "…" "$D/ready" '^APKTOOL_VERSION=7\.7\.7$'; has "…" "$D/ready" '^JADX_MCP_VERSION=6\.6\.6$'; has "…e TOOLS (com o rea)" "$D/ready" '^TOOLS=java jadx apktool rea$'; has "…a versão do rea" "$D/ready" '^REA_VERSION=5\.5\.5$'; has "…e o sha256 do lock do rea" "$D/ready" "^REA_LOCK_SHA256=$H_RLOCK$"
  has "…o npm rodou com ci --ignore-scripts" "$STUB_LOG" 'NPM:ci --ignore-scripts '; [ "$(readlink "$D/rea")" = "rea-5.5.5-${H_RLOCK:0:12}" ] && ok "…link rea (diretório por versão e lock)" || bad "…link rea errado"; [ -x "$D/bin/rea" ] && ok "…bin/rea executável" || bad "…sem bin/rea"; :
  has "…URL do JDK montada do pin (major, %2B e _)" "$STUB_LOG" 'CURL:https://github\.com/adoptium/temurin9-binaries/releases/download/jdk-9\.9\.9%2B1/OpenJDK9U-jdk_aarch64_linux_hotspot_9\.9\.9_1\.tar\.gz$'
  has "…URL do jadx" "$STUB_LOG" 'CURL:https://github\.com/skylot/jadx/releases/download/v8\.8\.8/jadx-8\.8\.8\.zip$'; has "…URL do apktool (Maven Central)" "$STUB_LOG" 'CURL:https://repo1\.maven\.org/maven2/org/apktool/apktool-cli/7\.7\.7/apktool-cli-7\.7\.7\.jar$'
  has "…URL do jar do REA" "$STUB_LOG" 'CURL:https://github\.com/1013503897/jadx-headless-mcp/releases/download/v6\.6\.6/jadx-headless-mcp-6\.6\.6-all\.jar$'
  [ "$(readlink "$D/jdk")" = "jdk-9.9.9+1" ] && ok "…link jdk" || bad "…link jdk errado"; [ "$(readlink "$D/jadx.jar")" = "jadx-8.8.8/jadx-8.8.8-all.jar" ] && ok "…link jadx.jar" || bad "…link jadx.jar errado"
  [ "$(readlink "$D/apktool.jar")" = "apktool-7.7.7/apktool-cli-7.7.7.jar" ] && ok "…link apktool.jar" || bad "…link apktool.jar errado"; [ "$(readlink "$D/jadx-headless-mcp.jar")" = "jadx-headless-mcp-6.6.6/jadx-headless-mcp-6.6.6-all.jar" ] && ok "…link do jar do REA" || bad "…link do jar do REA errado"
  [ -x "$D/bin/java" ] && [ -x "$D/bin/jadx" ] && [ -x "$D/bin/apktool" ] && [ -x "$D/bin/rea" ] && ok "…java, jadx, apktool e rea executáveis em bin/" || bad "…faltou executável em bin/"; has "…a saída diz ok" "$T/out" '^REATOOLS ok'; noleft "…"
  rc=$(run check); eq "check depois: rc 0" 0 "$rc"; has "…diz ok" "$T/out" '^REATOOLS ok'; }
c_idem() { installed; local rc; rc=$(run install); eq "install de novo: rc 0" 0 "$rc"; hasnt "…não baixa nada" "$STUB_LOG" 'CURL:'; }
c_sha() { local a=$1 rc; reset; stubset STUB_BAD="$a"; rc=$(run install); eq "sha256 errado ($a): rc 4" 4 "$rc"; has "…a recusa diz que o sha256 não confere" "$T/out" 'sha256 não confere'; noready "…"; noleft "…"; hasnt "…nada baixado foi executado (java)" "$STUB_LOG" 'JAVA:'; }
c_sha_jdk() { c_sha jdk; }; c_sha_zip() { c_sha zip; }; c_sha_apk() { c_sha apk; }; c_sha_mcp() { c_sha mcp; }
c_sha_jar_no_zip() { reset; mkpin "JADX_JAR_SHA256=$H_MAU"; local rc; rc=$(run install); eq "sha256 do jar de DENTRO do zip errado: rc 4" 4 "$rc"; has "…diz que é o jar de dentro do zip" "$T/out" 'jar de dentro do zip do jadx'; noready "…"; }
c_zip_sem_membro() { reset; mkpin "JADX_ZIP_SHA256=$H_NOMEM"; stubset STUB_ZIP_FILE=jadx-nomember.zip; local rc; rc=$(run install); eq "zip do jadx sem lib/jadx-<v>-all.jar: rc 4" 4 "$rc"; has "…nomeia o jar que faltou" "$T/out" 'lib/jadx-8\.8\.8-all\.jar'; noready "…"; }
c_mcp_sem_classe() { reset; mkpin "JADX_MCP_JAR_SHA256=$H_MCPBAD"; stubset STUB_MCP_FILE=mcp-bad.jar; local rc; rc=$(run install); eq "jar do REA sem uma das classes: rc 4" 4 "$rc"; has "…diz que faltam classes do REA" "$T/out" 'classes que o REA confere'; noready "…"; }
c_tar_sem_java() { reset; mkpin "JDK_SHA256_LINUX_ARM64=$H_NOJAVA"; stubset STUB_JDK_FILE=jdk-nojava.tgz; local rc; rc=$(run install); eq "tar do JDK sem bin/java: rc 4" 4 "$rc"; has "…diz que falta o java" "$T/out" 'bin/java'; noready "…"; }
c_jdk_versao() { reset; stubset STUB_JDK_VER=9.9.8+1; local rc; rc=$(run install); eq "java de outra versão que o pin: rc 4" 4 "$rc"; has "…nomeia as duas" "$T/out" "9\.9\.8\+1.*9\.9\.9\+1"; noready "…"; }
c_sem_compiler() { reset; stubset STUB_COMPILER=0; local rc; rc=$(run install); eq "JDK sem jdk.compiler: rc 4" 4 "$rc"; has "…diz que o REA exige JDK completo" "$T/out" 'jdk\.compiler'; noready "…"; }
c_jadx_versao() { reset; stubset STUB_JADX_VER=1.0.0; local rc; rc=$(run install); eq "jadx --version diz outra versão: rc 4" 4 "$rc"; has "…nomeia o jadx" "$T/out" 'jadx --version diz'; noready "…"; }
c_apk_versao() { reset; stubset STUB_APK_VER=1.0.0; local rc; rc=$(run install); eq "apktool --version diz outra versão: rc 4" 4 "$rc"; has "…nomeia o apktool" "$T/out" 'apktool --version diz'; noready "…"; }
c_download_falha() { reset; stubset STUB_CURL_FAIL=1; local rc; rc=$(run install); eq "curl falha: rc 5" 5 "$rc"; has "…a recusa nomeia o download" "$T/out" 'download falhou'; noready "…"; noleft "…"; }
c_marcador_cai() { installed; mkpin "JADX_VERSION=8.8.9" "JADX_ZIP_SHA256=$H_MAU"; local rc; rc=$(run install); eq "install com o marcador antigo, versão nova do jadx e zip com sha errado: rc 4" 4 "$rc"; noready "…o marcador antigo caiu e não voltou"; has "…a saída diz que o --exec volta ao MBP" "$T/out" 'o --exec segue no MBP'
  rc=$(run check); eq "…e o check seguinte diz ausente (rc 1)" 1 "$rc"; has "…" "$T/out" '^REATOOLS ausente'; }
c_wrappers() { installed; : > "$STUB_LOG"; "$D/bin/jadx" -d out in.apk >/dev/null 2>&1; has "jadx: o heap padrão é 4096 m" "$STUB_LOG" 'JAVA:-Xmx4096m .*-cp .*/rea-tools/jadx\.jar jadx\.cli\.JadxCLI -d out in\.apk$'
  : > "$STUB_LOG"; JADX_HEAP_MB=1024 "$D/bin/jadx" x >/dev/null 2>&1; has "jadx: JADX_HEAP_MB troca o heap" "$STUB_LOG" 'JAVA:-Xmx1024m '
  : > "$STUB_LOG"; JADX_HEAP_MB=abc "$D/bin/jadx" x >/dev/null 2>&1; has "jadx: valor lixo volta ao padrão" "$STUB_LOG" 'JAVA:-Xmx4096m '
  : > "$STUB_LOG"; "$D/bin/apktool" d in.apk >/dev/null 2>&1; has "apktool: heap padrão 2048 m e -jar do apktool.jar" "$STUB_LOG" 'JAVA:-Xmx2048m .*-jar .*/rea-tools/apktool\.jar d in\.apk$'
  : > "$STUB_LOG"; APKTOOL_HEAP_MB=512 "$D/bin/apktool" d x >/dev/null 2>&1; has "apktool: APKTOOL_HEAP_MB troca o heap" "$STUB_LOG" 'JAVA:-Xmx512m '
  : > "$STUB_LOG"; "$D/bin/java" -version >/dev/null 2>&1; has "bin/java é o java do JDK do pin" "$STUB_LOG" 'JAVA:-version$'; }
c_arch() { reset; stubset STUB_ARCH=x86_64; local rc; rc=$(run check); eq "check em x86_64: rc 3" 3 "$rc"; rc=$(run install); eq "install em x86_64: rc 3" 3 "$rc"; hasnt "…não baixa nada" "$STUB_LOG" 'CURL:'; }
c_pin_ausente() { reset; local rc; rc=$(run check --pin "$T/nao-existe"); eq "pin ausente: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_pin_repetido() { reset; printf 'JDK_VERSION=9.9.9+1\n' >> "$PINF"; local rc; rc=$(run check); eq "JDK_VERSION repetida: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; }
c_pin_formato() { reset; mkpin "JADX_ZIP_SHA256=abc"; local rc; rc=$(run check); eq "sha256 fora do formato: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'
  mkpin "JDK_VERSION=9.9.9"; rc=$(run check); eq "JDK_VERSION sem o +build: rc 2" 2 "$rc"; mkpin 'APKTOOL_VERSION=7.7.7; touch '"$T"'/pwned'; rc=$(run install); eq "versão com injeção: rc 2" 2 "$rc"; hasnt "…não chamou o ssh" "$STUB_LOG" 'SSH:'; [ -e "$T/pwned" ] && bad "…o comando injetado rodou" || ok "…e nada foi criado"; }
c_ssh_cai() { reset; stubset STUB_SSH_RC=255; local rc; rc=$(run check); eq "ssh caiu: rc 2" 2 "$rc"; has "…NAO-CONSEGUI, não 'ausente'" "$T/out" 'NAO-CONSEGUI'; hasnt "…não diz ausente" "$T/out" '^REATOOLS ausente'; }
c_ssh_cai_depois() { reset; stubset STUB_SSH_RC_AFTER=255; local rc; rc=$(run check); eq "ssh caiu depois de responder: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_sem_fim() { reset; stubset STUB_SSH_DROP_FIM=1; local rc; rc=$(run check); eq "resposta sem a sentinela FIM: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_arch_sem_linha() { reset; stubset STUB_SSH_DROP_LINE=ARCH; local rc; rc=$(run check); eq "resposta com FIM mas sem a linha ARCH: rc 2 (não 3)" 2 "$rc"; hasnt "…não diz 'arquitetura'" "$T/out" '^REATOOLS arquitetura'; }
c_sem_mark() { reset; stubset STUB_SSH_DROP_LINE=MARK; local rc; rc=$(run check); eq "resposta sem a linha MARK: rc 2 (não 'ausente')" 2 "$rc"; hasnt "…não diz ausente" "$T/out" '^REATOOLS ausente'; }
c_sem_linha() { local l=$1; installed; stubset STUB_SSH_DROP_LINE="$l"; local rc; rc=$(run check); eq "marcador presente e resposta sem a linha $l: rc 2 (não 'ok')" 2 "$rc"; hasnt "…não diz ok" "$T/out" '^REATOOLS ok'; }
c_sem_jdk_linha() { c_sem_linha JDK; }; c_sem_jadxjar_linha() { c_sem_linha JADXJAR; }; c_sem_mcpcls_linha() { c_sem_linha MCPCLS; }; c_sem_jadxv_linha() { c_sem_linha JADXV; }
c_quebrado_jar() { installed; printf 'adulterado' > "$D/jadx-8.8.8/jadx-8.8.8-all.jar"; local rc; rc=$(run check); eq "jar do jadx adulterado: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o sha256 do jar do jadx" "$T/out" 'sha256 do jar do jadx'
  rc=$(run install); eq "install conserta: rc 0" 0 "$rc"; rc=$(run check); eq "…e o check seguinte diz ok" 0 "$rc"; }
c_quebrado_mcp() { installed; cp "$FIX/mcp-extra.jar" "$D/jadx-headless-mcp-6.6.6/jadx-headless-mcp-6.6.6-all.jar"; local rc; rc=$(run check); eq "jar do REA com as classes mas bytes diferentes: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o sha256 do jar do REA" "$T/out" 'sha256 do jar do REA'; }
c_quebrado_java() { installed; find "$D/jdk-9.9.9+1" -mindepth 1 -delete; local rc; rc=$(run check); eq "JDK sumido: check rc 1 (java que não roda ≠ ok)" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o java do JDK" "$T/out" 'o java do JDK'; }
c_quebrado_compiler() { installed; stubset STUB_COMPILER=0; local rc; rc=$(run check); eq "JDK sem jdk.compiler depois do install: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o jdk.compiler" "$T/out" 'jdk\.compiler'; }
c_quebrado_classes() { installed; mkpin "JADX_MCP_JAR_SHA256=$H_MCPBAD"; cp "$FIX/mcp-bad.jar" "$D/jadx-headless-mcp-6.6.6/jadx-headless-mcp-6.6.6-all.jar"; local rc; rc=$(run check); eq "jar do REA com o hash do pin mas sem uma classe: check rc 1" 1 "$rc"; has "…diz quebrado e as classes" "$T/out" 'as classes do REA'; }
c_quebrado_jadxv() { installed; stubset STUB_JADX_VER=1.0.0; local rc; rc=$(run check); eq "jadx --version diz outra versão: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; }
c_marcador_ilegivel() { installed; printf 'lixo\n' > "$D/ready"; local rc; rc=$(run check); eq "marcador sem as chaves: check rc 1" 1 "$rc"; has "…diz quebrado (não diferente, não ok)" "$T/out" '^REATOOLS quebrado'; }
c_marcador_outro() { installed; mkpin "JADX_VERSION=8.8.9"; local rc; rc=$(run check); eq "marcador de outra versão do pin: check rc 1" 1 "$rc"; has "…diz diferente (não ok)" "$T/out" '^REATOOLS diferente'; }
c_install_ssh_cai() { reset; stubset STUB_SSH_RC_INSTALL=255; local rc; rc=$(run install); eq "install: ssh cai na chamada do install: rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; noready "…"; }
c_install_ssh_cai_depois() { reset; stubset STUB_SSH_RC_AFTER_INSTALL=255; local rc; rc=$(run install); eq "install: ssh cai DEPOIS de o install rodar (saída completa, rc 255): rc 2" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_install_sem_fim() { reset; stubset STUB_SSH_DROP_FIM_INSTALL=1; local rc; rc=$(run install); eq "install: resposta do install sem a sentinela FIM: rc 2" 2 "$rc"; has "…diz que faltou a sentinela" "$T/out" 'sentinela FIM'; }
c_conferencia_final_nao_le() { reset; stubset STUB_SSH_FAIL_PROBE_N=2; local rc; rc=$(run install); eq "install ok mas a sonda FINAL não consegue ler: rc 2 (não 1)" 2 "$rc"; has "…NAO-CONSEGUI" "$T/out" 'NAO-CONSEGUI'; }
c_usage() { reset; local rc; rc=$(run); eq "sem subcomando: rc 64 (uso errado), não 2" 64 "$rc"; rc=$(run install --pin); eq "--pin sem argumento: rc 64" 64 "$rc"; }

# ---- o rea (ga-03w2fck) ---------------------------------------------------------------------------------------------------------
noinstall() { hasnt "$1: o install NÃO foi chamado no nó" "$STUB_LOG" 'SSH:.*bash -s -- '; hasnt "…e nada foi baixado" "$STUB_LOG" 'CURL:'; hasnt "…nem o npm rodou" "$STUB_LOG" 'NPM:'; }
c_rea_lock_sha() { reset; printf '\n' >> "$RLIB/package-lock.json"; local rc; rc=$(run install); eq "lock do rea com sha256 diferente do pin: rc 4" 4 "$rc"; has "…nomeia o lock e o sha256 do pin" "$T/out" 'package-lock\.json tem sha256 .* e o pin diz'; noready "…"; noinstall "…"; mkrea_lock; }
mkrea_lock() { printf '{\n  "lockfileVersion": 3,\n  "packages": {\n    "": { "dependencies": { "rea-agents": "5.5.5" } },\n    "node_modules/rea-agents": { "version": "5.5.5", "integrity": "%s" }\n  }\n}\n' "$RINTEG" > "$RLIB/package-lock.json"; }
c_rea_lock_integrity() { reset; local old; old=$(cat "$RLIB/package-lock.json"); local other="sha512-$(printf 'B%.0s' $(seq 1 86))=="
  printf '{\n  "lockfileVersion": 3,\n  "packages": {\n    "": {},\n    "node_modules/rea-agents": { "version": "5.5.5", "integrity": "%s" }\n  }\n}\n' "$other" > "$RLIB/package-lock.json"
  mkpin "REA_LOCK_SHA256=$(sha_of "$RLIB/package-lock.json")"; local rc; rc=$(run install); eq "lock com o rea-agents de OUTRO integrity que o pin (sha256 do lock bate): rc 4" 4 "$rc"; has "…nomeia o que o lock traz e o que o pin pede" "$T/out" 'o lock traz .*para o rea-agents e o pin é'; noready "…"; noinstall "…"; mkrea_lock; }
c_rea_lock_versao() { reset; printf '{\n  "lockfileVersion": 3,\n  "packages": {\n    "": {},\n    "node_modules/rea-agents": { "version": "5.5.4", "integrity": "%s" }\n  }\n}\n' "$RINTEG" > "$RLIB/package-lock.json"
  mkpin "REA_LOCK_SHA256=$(sha_of "$RLIB/package-lock.json")"; local rc; rc=$(run install); eq "lock com outra VERSÃO do rea-agents (sha256 e integrity batem): rc 4" 4 "$rc"; noready "…"; noinstall "…"; mkrea_lock; }
c_rea_lock_ausente() { reset; mv "$RLIB/package-lock.json" "$RLIB/lock.off"; local rc; rc=$(run install); eq "lock do rea ausente: rc 4" 4 "$rc"; noready "…"; noinstall "…"; mv "$RLIB/lock.off" "$RLIB/package-lock.json"; }
c_rea_pkg_ausente() { reset; mv "$RLIB/package.json" "$RLIB/pkg.off"; local rc; rc=$(run install); eq "package.json do rea ausente: rc 4" 4 "$rc"; has "…diz qual" "$T/out" 'package\.json ilegível ou ausente'; noready "…"; noinstall "…"; mv "$RLIB/pkg.off" "$RLIB/package.json"; }
c_rea_lock_transito() { reset; stubset STUB_CORRUPT_LOCK=1; local rc; rc=$(run install); eq "lock adulterado EM TRÂNSITO (o mini conferiu, o nó confere de novo): rc 4" 4 "$rc"; has "…o nó recusa pelo sha256 do lock" "$T/out" 'sha256 do lock do rea não confere com o pin'; noready "…"; hasnt "…o npm não rodou" "$STUB_LOG" 'NPM:'; noleft "…"; }
c_rea_sem_node() { reset; rm -f "$FAKE_HOME/.local/bin/node"; local rc; rc=$(run install); eq "nó sem node em ~/.local/bin: rc 4" 4 "$rc"; has "…manda rodar o hetzner-nodejs.sh" "$T/out" 'hetzner-nodejs\.sh install'; noready "…"; hasnt "…o npm não rodou" "$STUB_LOG" 'NPM:'; }
c_rea_sem_npm() { reset; rm -f "$FAKE_HOME/.local/node/bin/npm"; local rc; rc=$(run install); eq "nó sem npm: rc 4" 4 "$rc"; noready "…"; }
c_rea_npm_falha() { reset; stubset STUB_NPM_FAIL=1; local rc; rc=$(run install); eq "npm ci falha: rc 5" 5 "$rc"; has "…diz que o npm ci falhou" "$T/out" 'npm ci do rea falhou'; noready "…"; noleft "…"; [ -e "$D/rea" ] && bad "…o link rea NÃO pode existir" || ok "…sem link rea"; }
c_rea_versao() { reset; stubset STUB_REA_VER=5.5.4; local rc; rc=$(run install); eq "rea que diz outra versão que o pin: rc 4" 4 "$rc"; has "…nomeia as duas" "$T/out" "o rea instalado diz '5\.5\.4' e o pin é 5\.5\.5"; noready "…"; noleft "…"; }
c_rea_versao_final() { reset; stubset STUB_REA_BAD_FINAL=1; local rc; rc=$(run install); eq "rea que só erra a versão DEPOIS de ir para a pasta final (pelo wrapper): rc 4" 4 "$rc"; has "…diz que foi pelo wrapper" "$T/out" 'rea --version \(pelo wrapper\) diz'; noready "…"; }
c_rea_dir_real() { reset; mkdir -p "$D/rea"; : > "$D/rea/dono-alheio"; local rc; rc=$(run install); eq "\$D/rea que é DIRETÓRIO comum: rc 4" 4 "$rc"; has "…diz que não é link" "$T/out" 'existe e não é um link'; noready "…"; [ -e "$D/rea/dono-alheio" ] && ok "…e o conteúdo alheio ficou" || bad "…o conteúdo alheio foi tocado"; }
c_rea_wrapper() { installed; : > "$STUB_LOG"; local o; export HOME_REAL="$HOME"; o=$(HOME="$FAKE_HOME" "$D/bin/rea" inspect-android-package in/x.apk 2>&1); eq "bin/rea passa os argumentos ao rea pelo node do nó" "rea-args:inspect-android-package in/x.apk" "$o"
  o=$(HOME="$FAKE_HOME" "$D/bin/rea" --version 2>&1); eq "…e --version devolve a versão do pin" "5.5.5" "$o"; rm -f "$FAKE_HOME/.local/bin/node"; HOME="$FAKE_HOME" "$D/bin/rea" --version >/dev/null 2>&1; local rc=$?; [ "$rc" -ge 126 ] && ok "…sem o node o wrapper sai $rc (126/127: o mbp-run manda ao MBP)" || bad "…sem o node o wrapper saiu $rc"; }
c_rea_idem() { installed; local rc; rc=$(run install); eq "install de novo com o rea: rc 0" 0 "$rc"; hasnt "…não rodou o npm" "$STUB_LOG" 'NPM:'; }
c_rea_marcador_antigo() { installed; sed -i.bak -e '/^REA_VERSION=/d' -e '/^REA_LOCK_SHA256=/d' -e 's/^TOOLS=.*/TOOLS=java jadx apktool/' "$D/ready"; local rc; rc=$(run check); eq "marcador de ANTES do rea (4 versões): check rc 1" 1 "$rc"; has "…diz quebrado e que faltam versões" "$T/out" '^REATOOLS quebrado.*cinco versões'; hasnt "…não diz ok" "$T/out" '^REATOOLS ok'
  rc=$(run install); eq "…o install migra: rc 0" 0 "$rc"; has "…e o marcador novo lista o rea" "$D/ready" '^TOOLS=java jadx apktool rea$'; }
c_rea_marcador_outro() { installed; mkpin "REA_VERSION=5.5.6"; local rc; rc=$(run check); eq "marcador com outra versão do rea que o pin: check rc 1" 1 "$rc"; has "…diz diferente" "$T/out" '^REATOOLS diferente'; has "…e nomeia o rea" "$T/out" 'rea 5\.5\.5'; }
c_rea_mark_curto() { installed; stubset STUB_SSH_SHORT_MARK=1; local rc; rc=$(run check); eq "linha MARK sem o 5º campo (truncada): check rc 1, nunca ok" 1 "$rc"; has "…diz quebrado e que faltam versões" "$T/out" '^REATOOLS quebrado.*cinco versões'; hasnt "…não diz ok" "$T/out" '^REATOOLS ok'; }
c_rea_tools_sem_rea() { installed; sed -i.bak 's/^TOOLS=.*/TOOLS=java jadx apktool/' "$D/ready"; local rc; rc=$(run check); eq "marcador com TOOLS= sem o rea (rea desligado): check rc 1, nunca ok" 1 "$rc"; has "…diz quebrado e nomeia o TOOLS=" "$T/out" '^REATOOLS quebrado.*TOOLS='; hasnt "…não diz ok" "$T/out" '^REATOOLS ok'
  rc=$(run install); eq "…o install religa o rea: rc 0" 0 "$rc"; has "…e o marcador volta a listar o rea" "$D/ready" '^TOOLS=java jadx apktool rea$'; rc=$(run check); eq "…e o check seguinte diz ok" 0 "$rc"; }
c_sem_tools_linha() { c_sem_linha TOOLS; }
c_quebrado_rea_versao() { installed; stubset STUB_REA_VER=5.5.4; local rc; rc=$(run check); eq "rea --version diz outra versão: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o rea --version" "$T/out" 'rea --version'; }
c_quebrado_rea_lock() { installed; printf '\n' >> "$D/rea/package-lock.json"; local rc; rc=$(run check); eq "package-lock.json instalado adulterado: check rc 1" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; has "…e o sha256 do lock" "$T/out" 'sha256 do package-lock\.json do rea'; }
c_quebrado_rea_sumiu() { installed; rm -f "$D/bin/rea"; local rc; rc=$(run check); eq "bin/rea sumiu: check rc 1 (rea que não roda ≠ ok)" 1 "$rc"; has "…diz quebrado" "$T/out" '^REATOOLS quebrado'; }
c_sem_reav_linha() { c_sem_linha REAV; }; c_sem_realock_linha() { c_sem_linha REALOCK; }
CASES="c_vazio c_feliz c_idem c_sha_jdk c_sha_zip c_sha_apk c_sha_mcp c_sha_jar_no_zip c_zip_sem_membro c_mcp_sem_classe c_tar_sem_java c_jdk_versao c_sem_compiler c_jadx_versao c_apk_versao c_download_falha c_marcador_cai c_wrappers c_arch c_pin_ausente c_pin_repetido c_pin_formato c_ssh_cai c_ssh_cai_depois c_sem_fim c_arch_sem_linha c_sem_mark c_sem_jdk_linha c_sem_jadxjar_linha c_sem_mcpcls_linha c_sem_jadxv_linha c_quebrado_jar c_quebrado_mcp c_quebrado_java c_quebrado_compiler c_quebrado_classes c_quebrado_jadxv c_marcador_ilegivel c_marcador_outro c_install_ssh_cai c_install_ssh_cai_depois c_install_sem_fim c_conferencia_final_nao_le c_usage c_rea_lock_sha c_rea_lock_integrity c_rea_lock_versao c_rea_lock_ausente c_rea_pkg_ausente c_rea_lock_transito c_rea_sem_node c_rea_sem_npm c_rea_npm_falha c_rea_versao c_rea_versao_final c_rea_dir_real c_rea_wrapper c_rea_idem c_rea_marcador_antigo c_rea_tools_sem_rea c_sem_tools_linha c_rea_mark_curto c_rea_marcador_outro c_quebrado_rea_versao c_quebrado_rea_lock c_quebrado_rea_sumiu c_sem_reav_linha c_sem_realock_linha"
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
mutant sem-conferir-sha        '| sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 não confere com o pin: $(basename "$2")"; exit 4; }' '| cat >/dev/null 2>&1 || true'  c_sha_jdk
mutant download-rc-ignorado    '-o "$2" "$1" || { echo "RECUSO download falhou: $1"; exit 5; }'  '-o "$2" "$1" || true'                          c_download_falha
mutant marcador-nao-cai        'rm -f "$D/ready" "$D/ready.tmp"'                                  'true'                                          c_marcador_cai
mutant sem-conferir-jar-no-zip '>/dev/null 2>&1 || { echo "RECUSO sha256 do jar de dentro do zip do jadx não confere com o pin"; exit 4; }' '>/dev/null 2>&1 || true' c_sha_jar_no_zip
mutant zip-sem-membro-ignorado '|| { echo "RECUSO o zip do jadx não traz lib/jadx-$XV-all.jar"; exit 4; }' '|| true'                         c_zip_sem_membro
mutant sem-classes-do-rea      'mcp_ok "$W/mcp.jar" || { echo "RECUSO o jar do REA não traz as classes que o REA confere"; exit 4; }' 'true' c_mcp_sem_classe
mutant jdk-sem-bin-java        '[ -x "$J/bin/java" ] || { echo "RECUSO o tar do JDK não traz jdk-$JV/bin/java"; exit 4; }' 'true'                c_tar_sem_java
mutant jdk-versao-nao-compara  '[ "$v" = "$JV" ] ||'                                              'true ||'                                       c_jdk_versao
mutant sem-jdk-compiler        '| grep -q '"'"'^jdk\.compiler@'"'"' || { echo "RECUSO o JDK não tem o módulo jdk.compiler (o REA exige JDK completo)"; exit 4; }' '|| true' c_sem_compiler
mutant jadx-versao-nao-compara '[ "$v" = "$XV" ] ||'                                              'true ||'                                       c_jadx_versao
mutant apktool-versao-nao-compara '[ "$v" = "$AV" ] ||'                                           'true ||'                                       c_apk_versao
mutant wrapper-sem-heap        '"-Xmx${JADX_HEAP_MB}m"'                                           ''                                              c_wrappers
mutant arquitetura-ignorada    '[ "$arch" = "Linux aarch64" ] ||'                                 'true ||'                                       c_arch
mutant arch-vazio-vira-arquitetura '[ -n "$arch" ] || {'                                          'true || {'                                     c_arch_sem_linha
mutant mark-vazio-vira-ausente '[ -n "$mark" ] || { STATE=nao-consegui'                           'true || { STATE=nao-consegui'                  c_sem_mark
mutant marcador-nao-compara    'if [ "$mj" != "$JDK_VERSION" ] || [ "$mx" != "$JADX_VERSION" ] || [ "$ma" != "$APKTOOL_VERSION" ] || [ "$mm" != "$JADX_MCP_VERSION" ] || [ "$mr" != "$REA_VERSION" ]; then' 'if false; then' c_marcador_outro
mutant marcador-ilegivel-vale  '*" ilegivel "*) STATE=quebrado'                                   '*" XX "*) STATE=quebrado'                      c_marcador_ilegivel
mutant jar-do-jadx-nao-compara 'want JADXJAR "$JADX_JAR_SHA256" "sha256 do jar do jadx" &&'       ''                                              c_quebrado_jar
mutant jar-do-rea-nao-compara  'want MCPJAR "$JADX_MCP_JAR_SHA256" "sha256 do jar do REA" &&'     ''                                              c_quebrado_mcp
mutant jdk-nao-compara-no-check 'want JDK "$JDK_VERSION" "o java do JDK" &&'                      ''                                              c_quebrado_java
mutant compiler-nao-compara    'want COMP 1 "jdk.compiler (1 = tem)" &&'                          ''                                              c_quebrado_compiler
mutant classes-nao-comparam    'want MCPCLS 1 "as classes do REA no jar (1 = tem)" &&'            ''                                              c_quebrado_classes
mutant jadxv-nao-compara       'want JADXV "$JADX_VERSION" "jadx --version" &&'                   ''                                              c_quebrado_jadxv
mutant linha-ausente-vira-ok   '[ -n "$v" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha $1"; return 1; }' 'true' c_sem_jadxjar_linha
mutant ssh-rc-ignorado         'if [ $rc -ne 0 ] || ! printf'                                     'if false || ! printf'                          c_ssh_cai_depois
mutant sem-sentinela           "|| ! printf '%s\\n' \"\$out\" | grep -qx 'FIM'; then STATE=nao-consegui" '; then STATE=nao-consegui'              c_sem_fim
mutant sem-idempotencia        'ok) report; exit 0 ;;'                                            'ok) ;;'                                        c_idem
mutant pin-sem-regex           '[[ "$v" =~ $re ]] ||'                                             'true ||'                                       c_pin_formato
mutant pasta-temporaria-fica   "trap 'find \"\$W\" -mindepth 1 -delete 2>/dev/null; rmdir \"\$W\" 2>/dev/null' EXIT" 'true'                     c_sha_zip
mutant conferencia-final-pulada 'probe
report; exit $?' 'STATE=ok; DETAIL="(mutante)"
report; exit $?' c_conferencia_final_nao_le
mutant ssh-255-do-install-ignorado '255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;' '255) ;;' c_install_ssh_cai_depois
mutant sem-fim-do-install-ignorado "printf '%s\\n' \"\$out\" | grep -qx 'FIM' || die 2" 'true || die 2' c_install_sem_fim
mutant usage-sai-2             'usage() { echo "uso: hetzner-rea-tools.sh check|install [--pin ARQUIVO]" >&2; exit 64; }' 'usage() { echo "uso: hetzner-rea-tools.sh check|install [--pin ARQUIVO]" >&2; exit 2; }' c_usage

mutant rea-lock-nao-conferido-no-mini 'got=$(sha_of "$LIBS/package-lock.json")
[ "$got" = "$REA_LOCK_SHA256" ] ||' 'got=$(sha_of "$LIBS/package-lock.json")
true ||' c_rea_lock_sha
mutant rea-integrity-nao-conferido 'print(e.get("version", "") + " " + e.get("integrity", ""))' 'print("'"'"'$REA_VERSION'"'"' '"'"'$REA_INTEGRITY'"'"'")' c_rea_lock_integrity
mutant rea-lock-nao-conferido-no-no '| sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 do lock do rea não confere com o pin"; exit 4; }' '| cat >/dev/null 2>&1 || true' c_rea_lock_transito
mutant rea-sem-checar-node  '[ -x "$RNODE" ] && [ -x "$RNPM" ] || {' 'true || {' c_rea_sem_node
mutant rea-npm-rc-ignorado  '>"$W/npm.log" 2>&1 ) || { echo "RECUSO npm ci do rea falhou' '>"$W/npm.log" 2>&1 ) || true; true || { echo "RECUSO npm ci do rea falhou' c_rea_npm_falha
mutant rea-versao-nao-compara 'v=$("$RNODE" "$W/rea/node_modules/rea-agents/scripts/rea.mjs" --version 2>&1 | tail -n 1); [ "$v" = "$RV" ] ||' 'v=$("$RNODE" "$W/rea/node_modules/rea-agents/scripts/rea.mjs" --version 2>&1 | tail -n 1); true ||' c_rea_versao
mutant rea-wrapper-versao-nao-compara 'v=$("$D/bin/rea" --version 2>&1 | tail -n 1); [ "$v" = "$RV" ] ||' 'v=$("$D/bin/rea" --version 2>&1 | tail -n 1); true ||' c_rea_versao_final
mutant rea-dir-real-aceito  '[ ! -e "$D/rea" ] || [ -L "$D/rea" ] || {' 'true || {' c_rea_dir_real
mutant tools-nao-compara  'want TOOLS "$EXPECT_TOOLS" "TOOLS= do marcador (o que liga as ferramentas ao --exec do nó)" &&' '' c_rea_tools_sem_rea
mutant rea-sem-no-marcador  'TOOLS=java jadx apktool rea\n' 'TOOLS=java jadx apktool\n' c_feliz
mutant rea-marcador-sem-versao 'mr=${5:-ilegivel}' 'mr=${5:-$REA_VERSION}' c_rea_mark_curto
mutant rea-reav-nao-compara   'want REAV "$REA_VERSION" "rea --version" &&' '' c_quebrado_rea_versao
mutant rea-lock-instalado-nao-compara 'want REALOCK "$REA_LOCK_SHA256" "sha256 do package-lock.json do rea" \' ':\' c_quebrado_rea_lock
mutant rea-wrapper-sem-node-absoluto 'exec "$HOME/.local/bin/node" "$D/rea' 'exec node "$D/rea' c_rea_wrapper

echo
echo "$n verificações, $fails falha(s)"
[ "$fails" -eq 0 ]
