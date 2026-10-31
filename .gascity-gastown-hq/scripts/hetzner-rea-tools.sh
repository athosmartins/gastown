#!/usr/bin/env bash
# hetzner-rea-tools.sh — JDK completo, jadx, apktool e o jar do jadx do REA no nó Linux (Hetzner) em nível de USUÁRIO (ga-kfxzpt). Roda no MINI, fala com o nó por ssh e só escreve em ~/.local/share/rea-tools do usuário do nó. Doc: docs/runbooks/hetzner-rea-tools.md
#
# Contents
#   Para que serve · Subcomandos · Códigos de saída · Por que é seguro · Limites
#
# PARA QUE SERVE: o `mbp-run.sh --exec --node-first` (rea-run.sh) só manda ao nó o comando de REA/APK se o preflight dele diz `rea_tools=<lista>`, e quem escreve a lista é o marcador `ready` deste install. Sem o marcador o nó nem é tentado.
#   O que entra: o JDK 21 do Temurin (o REA exige JDK completo, com jdk.compiler, em JAVA_HOME absoluto), o jadx (wrapper `jadx`), o apktool (wrapper `apktool`; o REA só decodifica) e o jar jadx-headless-mcp que o REA usa (REA_JADX_MCP_JAR).
#   O nó é aarch64 (Ubuntu 24.04). Não instala o `rea` (muitos comandos dele pedem Ghidra/Hopper/macOS: runbook, "O que falta") nem o Ghidra.
# SUBCOMANDOS: check [--pin ARQ] · install [--pin ARQ]      (pin padrão: scripts/hetzner-rea-tools.pin; HETZNER_REA_TOOLS_PIN troca)
#   check    só LÊ o nó (e roda de verdade java, jadx --version e apktool --version). ok = marcador `ready` igual ao pin + java do JDK do pin com jdk.compiler + sha256 dos três jars igual ao pin + as 5 classes que o REA confere no jar dele
#            + jadx e apktool dizem a versão do pin.
#   install  1) tira o marcador (o nó sai das execuções) 2) baixa os quatro artefatos para uma pasta temporária e confere o sha256 de CADA UM contra o pin (que vem do mini) ANTES de abrir ou rodar qualquer coisa 3) extrai o JDK e exige
#            Temurin-<versão do pin> + jdk.compiler; tira só o jar de dentro do zip do jadx (python zipfile, sem extrair o zip) e confere o sha256 dele; exige as classes do REA no jar dele 4) põe cada um numa pasta da própria versão,
#            religa os links (jdk, jadx.jar, apktool.jar, jadx-headless-mcp.jar) e escreve os wrappers 5) roda jadx --version e apktool --version 6) SÓ ENTÃO grava o marcador. Já está igual ao pin = não baixa nada (rc 0).
# CÓDIGOS: 0 ok / instalado · 1 check: ausente, quebrado ou diferente do pin · install: depois de instalar a conferência final LEU o nó e ele não está ok (se não conseguiu ler é rc 2) · 2 NÃO consegui saber (pin ilegível ou ambíguo, ssh caiu,
#   saída que não reconheço; nunca vira "ausente") · 3 o nó não é o que o pin cobre (SO/arquitetura) · 4 recusado (sha256 não confere, JDK de outra versão ou sem jdk.compiler, jar sem as classes do REA, ferramenta que não roda) · 5 download falhou · 64 uso errado (nunca 2)
# POR QUE É SEGURO: o marcador é a ÚNICA coisa que liga o nó ao --exec; meia instalação não vale. Ele cai no começo do install e só volta no fim, depois de jadx e apktool rodarem; qualquer recusa no meio deixa o nó SEM marcador (o --exec volta ao MBP).
#   Nenhum arquivo baixado é aberto antes do sha256 bater. O pin é DADO (lido por grep, nunca `source`) e versão e hash passam por regex antes de ir ao ssh. Não usa sudo nem apt e não toca fora de ~/.local/share/rea-tools; o `apktool` grava o
#   framework dele em ~/.local/share/apktool (cache próprio dele). O nó só decodifica: não há aapt2 para aarch64, então `apktool b` não é suportado.
# LIMITES: duas instalações ao mesmo tempo não são serializadas (não há lock) e um install durante um --exec troca arquivos que o job em curso pode estar usando: rode um install por vez, fora de execução. O que a prova de procedência NÃO cobre
#   está no cabeçalho do pin (as bibliotecas de terceiros do jar do jadx). Selftest: scripts/hetzner-rea-tools.selftest.sh (ssh, curl e uname são stubs; o script remoto roda de verdade num HOME temporário, com um JDK falso).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH_BIN=${MBP_SSH:-ssh}; HOST=${HETZNER_NODE_HOST:-hetzner-teste}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
PIN=${HETZNER_REA_TOOLS_PIN:-$HERE/hetzner-rea-tools.pin}
RE_JDK='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\+[0-9]{1,3}$'; RE_VER='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; RE_SHA='^[0-9a-f]{64}$'
say() { echo "REATOOLS $*"; }
die() { local rc=$1; shift; say "$*"; exit "$rc"; }
usage() { echo "uso: hetzner-rea-tools.sh check|install [--pin ARQUIVO]" >&2; exit 64; }

cmd=${1:-}; [ -n "$cmd" ] && shift
case "$cmd" in check|install) ;; *) usage ;; esac
while [ $# -gt 0 ]; do case "$1" in --pin) [ $# -ge 2 ] || usage; PIN=$2; shift 2 ;; *) usage ;; esac; done

# O pin é DADO: nove linhas KEY=valor, cada uma exatamente uma vez. Ausente, ilegível, repetida ou fora do formato = rc 2 (não sei o que o nó deve ter), nunca um valor padrão.
pin_get() { local n; n=$(grep -c -E "^$1=" "$PIN" 2>/dev/null) || n=0; [ "$n" = 1 ] || return 1; grep -E "^$1=" "$PIN" | sed -e "s/^$1=//"; }
[ -r "$PIN" ] || die 2 "NAO-CONSEGUI: pin ilegível ou ausente ($PIN)"
for k in JDK_VERSION JDK_SHA256_LINUX_ARM64 JADX_VERSION JADX_ZIP_SHA256 JADX_JAR_SHA256 APKTOOL_VERSION APKTOOL_JAR_SHA256 JADX_MCP_VERSION JADX_MCP_JAR_SHA256; do
  # vazio → pin_get devolve 1 (rc 2 abaixo); falhou/ilegível → idem: nunca cai num valor padrão
  v=$(pin_get "$k") || die 2 "NAO-CONSEGUI: $PIN não tem $k exatamente uma vez"
  case "$k" in JDK_VERSION) re=$RE_JDK ;; *SHA256*) re=$RE_SHA ;; *) re=$RE_VER ;; esac
  [[ "$v" =~ $re ]] || die 2 "NAO-CONSEGUI: $k fora do formato ($re)"
  printf -v "$k" '%s' "$v"
done

# O que os dois scripts remotos compartilham: onde mora o ambiente e como ler a versão que o java do JDK diz ser dele.
remote_common() { cat <<'EOF'
D=$HOME/.local/share/rea-tools
# vazio → sem JDK ou java que não roda: o chamador trata como quebrado/ausente (nunca igual ao pin); falhou/ilegível → idem
jdk_ver() { "$D/jdk/bin/java" -version 2>&1 | sed -n 's/.*Temurin-\([0-9][0-9.+]*\).*/\1/p' | head -n 1; }
# as classes que o rea-agents 6.4.0 exige no jar dele (dist/android/JadxConfiguration.js, requireEngineArchive)
mcp_ok() { python3 -I -c 'import sys, zipfile
n = set(zipfile.ZipFile(sys.argv[1]).namelist())
sys.exit(0 if all(c in n for c in sys.argv[2:]) else 1)' "$1" com/atxx/jhmcp/JadxSession.class com/atxx/jhmcp/SessionHolder.class jadx/api/JadxDecompiler.class com/google/gson/Gson.class io/modelcontextprotocol/kotlin/sdk/server/Server.class; }
EOF
}

# Só LÊ (e roda java, jadx e apktool). Imprime ARCH, MARK e, se há marcador, JDK COMP JADXJAR APKJAR MCPJAR MCPCLS JADXV APKV, mais a sentinela FIM; sem a sentinela quem chama trata como "não consegui ler".
remote_probe() { remote_common; cat <<'EOF'
echo "ARCH $(uname -s) $(uname -m)"
if [ ! -e "$D/ready" ]; then echo "MARK ausente"; echo FIM; exit 0; fi
# vazio → chave sem valor no marcador = "ilegivel" (o mini diz quebrado); falhou/ilegível (grep não lê) → idem
mk() { grep -E "^$1=" "$D/ready" 2>/dev/null | head -n 1 | sed -e "s/^$1=//"; }
j=$(mk JDK_VERSION); x=$(mk JADX_VERSION); a=$(mk APKTOOL_VERSION); m=$(mk JADX_MCP_VERSION)
echo "MARK ${j:-ilegivel} ${x:-ilegivel} ${a:-ilegivel} ${m:-ilegivel}"
v=$(jdk_ver); echo "JDK ${v:-ERRO}"
if "$D/jdk/bin/java" --list-modules 2>/dev/null | grep -q '^jdk\.compiler@'; then echo "COMP 1"; else echo "COMP 0"; fi
for p in "JADXJAR jadx.jar" "APKJAR apktool.jar" "MCPJAR jadx-headless-mcp.jar"; do
  set -- $p; s=$(sha256sum "$D/$2" 2>/dev/null | awk '{print $1}'); echo "$1 ${s:-ausente}"
done
if mcp_ok "$D/jadx-headless-mcp.jar" 2>/dev/null; then echo "MCPCLS 1"; else echo "MCPCLS 0"; fi
v=$("$D/bin/jadx" --version 2>&1 | tail -n 1); echo "JADXV ${v:-ERRO}"
v=$("$D/bin/apktool" --version 2>&1 | tail -n 1); echo "APKV ${v:-ERRO}"
echo FIM
EOF
}

# Escreve só em ~/.local/share/rea-tools. Códigos: 3 arquitetura · 4 recusado · 5 download · 6 outra falha. O marcador `ready` cai no começo e é a ÚLTIMA coisa que volta.
remote_install() { remote_common; cat <<'EOF'
set -eu
JV=$1; JSHA=$2; XV=$3; XZSHA=$4; XJSHA=$5; AV=$6; ASHA=$7; MV=$8; MSHA=$9
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || { echo "RECUSO arquitetura $(uname -s) $(uname -m)"; exit 3; }
mkdir -p "$D"
rm -f "$D/ready" "$D/ready.tmp"
echo "STEP marcador-removido (o --exec volta ao MBP até o fim deste install)"
W=$(mktemp -d "$D/.install.XXXXXX"); trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT
fetch() { # url arquivo sha256: baixa e CONFERE antes de qualquer uso
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 -o "$2" "$1" || { echo "RECUSO download falhou: $1"; exit 5; }
  printf '%s  %s\n' "$3" "$2" | sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 não confere com o pin: $(basename "$2")"; exit 4; }
  echo "STEP sha256-ok $(basename "$2")"
}
MAJ=${JV%%.*}
fetch "https://github.com/adoptium/temurin$MAJ-binaries/releases/download/jdk-${JV//+/%2B}/OpenJDK${MAJ}U-jdk_aarch64_linux_hotspot_${JV//+/_}.tar.gz" "$W/jdk.tgz" "$JSHA"
fetch "https://github.com/skylot/jadx/releases/download/v$XV/jadx-$XV.zip" "$W/jadx.zip" "$XZSHA"
fetch "https://repo1.maven.org/maven2/org/apktool/apktool-cli/$AV/apktool-cli-$AV.jar" "$W/apktool.jar" "$ASHA"
fetch "https://github.com/1013503897/jadx-headless-mcp/releases/download/v$MV/jadx-headless-mcp-$MV-all.jar" "$W/mcp.jar" "$MSHA"
mkdir "$W/jdk" && tar -xzf "$W/jdk.tgz" -C "$W/jdk" || { echo "RECUSO o tar do JDK não abriu"; exit 4; }
J=$W/jdk/jdk-$JV
[ -x "$J/bin/java" ] || { echo "RECUSO o tar do JDK não traz jdk-$JV/bin/java"; exit 4; }
v=$("$J/bin/java" -version 2>&1 | sed -n 's/.*Temurin-\([0-9][0-9.+]*\).*/\1/p' | head -n 1)
[ "$v" = "$JV" ] || { echo "RECUSO o java do tar diz '${v:-nada}' e o pin é $JV"; exit 4; }
"$J/bin/java" --list-modules 2>/dev/null | grep -q '^jdk\.compiler@' || { echo "RECUSO o JDK não tem o módulo jdk.compiler (o REA exige JDK completo)"; exit 4; }
echo "STEP jdk-ok"
# só o jar sai do zip do jadx (um membro, nome montado da versão do pin); o zip em si já bateu o sha256
python3 -I -c 'import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, z.open(sys.argv[2]) as s, open(sys.argv[3], "wb") as d:
    shutil.copyfileobj(s, d)' "$W/jadx.zip" "lib/jadx-$XV-all.jar" "$W/jadx-all.jar" || { echo "RECUSO o zip do jadx não traz lib/jadx-$XV-all.jar"; exit 4; }
printf '%s  %s\n' "$XJSHA" "$W/jadx-all.jar" | sha256sum -c - >/dev/null 2>&1 || { echo "RECUSO sha256 do jar de dentro do zip do jadx não confere com o pin"; exit 4; }
mcp_ok "$W/mcp.jar" || { echo "RECUSO o jar do REA não traz as classes que o REA confere"; exit 4; }
echo "STEP jars-ok"
# o install confere o que baixou; só agora mexe nas pastas de versão (uma já existente é trocada pela conferida)
[ ! -e "$D/jdk-$JV" ] || mv "$D/jdk-$JV" "$W/jdk-anterior"
mv "$J" "$D/jdk-$JV"
mkdir -p "$D/jadx-$XV" "$D/apktool-$AV" "$D/jadx-headless-mcp-$MV" "$D/bin"
cp "$W/jadx-all.jar" "$D/jadx-$XV/jadx-$XV-all.jar"; cp "$W/apktool.jar" "$D/apktool-$AV/apktool-cli-$AV.jar"; cp "$W/mcp.jar" "$D/jadx-headless-mcp-$MV/jadx-headless-mcp-$MV-all.jar"
ln -sfn "jdk-$JV" "$D/jdk"; ln -sfn "jadx-$XV/jadx-$XV-all.jar" "$D/jadx.jar"; ln -sfn "apktool-$AV/apktool-cli-$AV.jar" "$D/apktool.jar"
ln -sfn "jadx-headless-mcp-$MV/jadx-headless-mcp-$MV-all.jar" "$D/jadx-headless-mcp.jar"; ln -sfn ../jdk/bin/java "$D/bin/java"
# o jadx do pin com heap LIMITADO (padrão 4 GB; o do jadx é 70% da RAM e tomaria o nó das outras sessões); JADX_HEAP_MB não numérico volta ao padrão
cat > "$D/bin/jadx" <<'W1'
#!/bin/sh
D=$(cd "$(dirname "$0")/.." && pwd -P) || exit 126
case "${JADX_HEAP_MB:-}" in ''|*[!0-9]*) JADX_HEAP_MB=4096 ;; esac
exec "$D/jdk/bin/java" "-Xmx${JADX_HEAP_MB}m" -XX:+IgnoreUnrecognizedVMOptions -Djdk.util.zip.disableZip64ExtraFieldValidation=true --enable-native-access=ALL-UNNAMED -cp "$D/jadx.jar" jadx.cli.JadxCLI "$@"
W1
cat > "$D/bin/apktool" <<'W2'
#!/bin/sh
D=$(cd "$(dirname "$0")/.." && pwd -P) || exit 126
case "${APKTOOL_HEAP_MB:-}" in ''|*[!0-9]*) APKTOOL_HEAP_MB=2048 ;; esac
exec "$D/jdk/bin/java" "-Xmx${APKTOOL_HEAP_MB}m" -Dfile.encoding=UTF-8 -Djdk.util.zip.disableZip64ExtraFieldValidation=true -Djdk.nio.zipfs.allowDotZipEntry=true -jar "$D/apktool.jar" "$@"
W2
chmod 755 "$D/bin/jadx" "$D/bin/apktool"
v=$("$D/bin/jadx" --version 2>&1 | tail -n 1); [ "$v" = "$XV" ] || { echo "RECUSO jadx --version diz '${v:-nada}' e o pin é $XV"; exit 4; }
v=$("$D/bin/apktool" --version 2>&1 | tail -n 1); [ "$v" = "$AV" ] || { echo "RECUSO apktool --version diz '${v:-nada}' e o pin é $AV"; exit 4; }
echo "STEP ferramentas-rodam"
printf 'JDK_VERSION=%s\nJADX_VERSION=%s\nAPKTOOL_VERSION=%s\nJADX_MCP_VERSION=%s\nTOOLS=java jadx apktool\nINSTALLED_AT=%s\n' "$JV" "$XV" "$AV" "$MV" "$(date -u +%FT%TZ)" > "$D/ready.tmp" && mv "$D/ready.tmp" "$D/ready"
echo "STEP marcador-gravado"
echo FIM
EOF
}

# Pergunta ao nó (só leitura) e classifica em STATE: ok · ausente · diferente · quebrado · arquitetura · nao-consegui. Não imprime nem sai: quem chama decide o rc.
STATE=; DETAIL=
get() { printf '%s\n' "$out" | grep -E "^$1 " | head -n 1 | sed -e "s/^$1 //"; }
# want <LINHA> <esperado> <o que é>: a linha tem de existir (senão nao-consegui) e ser igual ao esperado (senão quebrado); 0 = confere
want() { local v; v=$(get "$1"); [ -n "$v" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha $1"; return 1; }
  [ "$v" = "$2" ] || { STATE=quebrado; DETAIL="$3: o nó diz '${v:0:24}' e o pin é '${2:0:24}'"; return 1; }; return 0; }
probe() {
  local rc arch mark mj mx ma mm
  # vazio → sem sentinela FIM = nao-consegui (nunca "ausente"); falhou/ilegível (ssh rc≠0) → idem
  out=$(remote_probe | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- 2>/dev/null); rc=$?
  if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'FIM'; then STATE=nao-consegui; DETAIL="ssh para $HOST caiu (rc $rc) ou a resposta veio incompleta"; return 0; fi
  arch=$(get ARCH)
  # vazio → resposta sem a linha ARCH = nao-consegui (nunca "arquitetura outra"); lida e diferente → arquitetura
  [ -n "$arch" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha ARCH"; return 0; }
  [ "$arch" = "Linux aarch64" ] || { STATE=arquitetura; DETAIL="o nó é '${arch:-?}' e o pin cobre Linux aarch64"; return 0; }
  mark=$(get MARK)
  [ -n "$mark" ] || { STATE=nao-consegui; DETAIL="a resposta do nó veio sem a linha MARK"; return 0; }
  [ "$mark" != ausente ] || { STATE=ausente; DETAIL="não há o marcador ~/.local/share/rea-tools/ready no nó (o --exec não vai ao nó)"; return 0; }
  set -- $mark; mj=${1:-ilegivel}; mx=${2:-ilegivel}; ma=${3:-ilegivel}; mm=${4:-ilegivel}
  case " $mj $mx $ma $mm " in *" ilegivel "*) STATE=quebrado; DETAIL="o marcador existe e não tem as quatro versões legíveis"; return 0 ;; esac
  if [ "$mj" != "$JDK_VERSION" ] || [ "$mx" != "$JADX_VERSION" ] || [ "$ma" != "$APKTOOL_VERSION" ] || [ "$mm" != "$JADX_MCP_VERSION" ]; then
    STATE=diferente; DETAIL="o marcador diz JDK $mj, jadx $mx, apktool $ma, jar do REA $mm; o pin é $JDK_VERSION, $JADX_VERSION, $APKTOOL_VERSION, $JADX_MCP_VERSION"; return 0
  fi
  want JDK "$JDK_VERSION" "o java do JDK" && want COMP 1 "jdk.compiler (1 = tem)" && want JADXJAR "$JADX_JAR_SHA256" "sha256 do jar do jadx" && want APKJAR "$APKTOOL_JAR_SHA256" "sha256 do jar do apktool" \
    && want MCPJAR "$JADX_MCP_JAR_SHA256" "sha256 do jar do REA" && want MCPCLS 1 "as classes do REA no jar (1 = tem)" && want JADXV "$JADX_VERSION" "jadx --version" && want APKV "$APKTOOL_VERSION" "apktool --version" \
    && { STATE=ok; DETAIL="JDK $JDK_VERSION (com jdk.compiler), jadx $JADX_VERSION, apktool $APKTOOL_VERSION, jar do REA $JADX_MCP_VERSION: hashes do pin e as ferramentas rodam"; }
  return 0
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
say "instalando JDK $JDK_VERSION, jadx $JADX_VERSION, apktool $APKTOOL_VERSION e o jar do REA $JADX_MCP_VERSION no $HOST (hoje: $STATE)"
# vazio → sem FIM é incompleto (rc 2); falhou/ilegível → o rc do ssh/remoto decide abaixo
out=$(remote_install | "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- "$JDK_VERSION" "$JDK_SHA256_LINUX_ARM64" "$JADX_VERSION" "$JADX_ZIP_SHA256" "$JADX_JAR_SHA256" "$APKTOOL_VERSION" "$APKTOOL_JAR_SHA256" "$JADX_MCP_VERSION" "$JADX_MCP_JAR_SHA256" 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^(STEP|RECUSO) ' | sed -e 's/^/REATOOLS remoto: /'
case $rc in
  0) ;;
  3|4|5) say "recusado/falhou no nó (rc $rc): sem marcador, o --exec segue no MBP"; exit "$rc" ;;
  255) die 2 "NAO-CONSEGUI: o ssh para $HOST caiu no meio; rode check antes de tentar de novo" ;;
  *) die 1 "o instalador remoto saiu com rc $rc; rode check" ;;
esac
printf '%s\n' "$out" | grep -qx 'FIM' || die 2 "NAO-CONSEGUI: o instalador remoto terminou sem a sentinela FIM; rode check"
# a conferência final usa o mesmo report do check: não consegui ler = rc 2, li e não está ok = rc 1, ok = rc 0
probe
report; exit $?
