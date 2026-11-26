#!/usr/bin/env bash
# inventario.sh — Mini64 fatia 1 (ga-ke5w2ie.1): o que o Assistente de Migração NÃO leva sozinho ao mini novo.
#
# SÓ LEITURA. Roda no mini atual (macOS, bash 3.2) e escreve UM arquivo: <cidade>/docs/runbooks/mini64/01-inventario.md
# (cidade = duas pastas acima deste script). Sem sudo, sem rede, sem launchctl que mude estado, sem brew que instale e sem
# valor de segredo: o Keychain só vê `find-generic-password -s NOME` SEM -w/-g (vale o rc e a classe de acesso); o ssh só
# `ssh-keygen -l` de chave PÚBLICA, authorized_keys e known_hosts (arquivo de chave privada nunca é aberto); do plist só
# Label, Disabled e ProgramArguments. Nunca varre o $HOME: só caminhos nomeados aqui (doutrina ga-6cyp1l: Desktop, Documents,
# Downloads, Pictures, Movies, Music, ~/Library/CloudStorage e /Volumes disparam o aviso de TCC e ficam de fora).
#
# TRÊS ESTADOS. Toda sonda responde, responde vazio ou não consegue dizer. O doc escreve «nenhum» só quando o comando
# respondeu vazio; comando ausente, rc ≠ 0, prazo estourado, saída fora do formato e arquivo ilegível viram «não apurado:
# motivo», nunca «nenhum», nunca 0, nunca «habilitado». Cada sonda leva prazo (perl alarm; sem perl no PATH só vale o orçamento entre sondas) e o script todo, um orçamento.
# Antes de gravar, o doc é varrido por padrões de segredo (chave privada, tokens conhecidos, hex/base64 longo): o que casa
# vira [suprimido] e o doc diz quantas linhas. Gravação atômica (mv); a pasta .inventario-work.* mora em
# docs/runbooks/mini64/ e some ao sair.
#
# Ambiente (usado pelo selftest): MINI64_CITY, MINI64_ROOT (prefixo dos caminhos absolutos do sistema; vazio no mini),
# MINI64_BUDGET_S (105), MINI64_PROBE_S (teto por sonda, 30),
# MINI64_SCAN_ROOTS (pastas onde procurar NOMES de segredo; padrão = scripts e packs da cidade, ~/.local/bin,
# ~/.gastown/scripts e ~/gt/*/{launchd,daemons,lib,scripts,bin,deploy}), MINI64_EXTRA_PATH (acrescentado ao PATH).
# bash 3.2: sem array associativo, mapfile, [[ =~ ]], ${x^^}. Sai 0 com o doc escrito (mesmo com seções «não apuradas»);
# 1 se não deu para escrever o doc; 2 sem HOME.
set -u
num() { case "$1" in (''|*[!0-9]*) echo "$2" ;; (*) echo "$1" ;; esac; }
case "${HOME:-}" in (/*) H="$HOME" ;; (*) echo "inventario: HOME vazio ou relativo; nada foi lido" >&2; exit 2 ;; esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "inventario: não achei a pasta do script" >&2; exit 1; }
CITY="${MINI64_CITY:-$(cd "$HERE/../.." && pwd)}"; R="${MINI64_ROOT:-}"   # R = prefixo dos caminhos absolutos do sistema (vazio em produção)
OUT_DIR="$CITY/docs/runbooks/mini64"; DOC="$OUT_DIR/01-inventario.md"
BUDGET=$(num "${MINI64_BUDGET_S:-}" 105); PMAX=$(num "${MINI64_PROBE_S:-}" 30)
PATH="$PATH${MINI64_EXTRA_PATH-:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$H/.local/bin:$H/go/bin}"
export PATH LC_ALL=C HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
WORK="$(mkdir -p "$OUT_DIR" 2>/dev/null && mktemp -d "$OUT_DIR/.inventario-work.XXXXXX" 2>/dev/null)" \
  || { echo "inventario: não consegui criar a pasta de trabalho em $OUT_DIR" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
BODY="$WORK/body.md"; SUMM="$WORK/summary.tsv"; PL="$WORK/plists.tsv"; : >"$BODY"; : >"$SUMM"; : >"$PL"
HAVE_PERL=0; command -v perl >/dev/null 2>&1 && HAVE_PERL=1
# prazo por sonda: o filho roda em grupo próprio; estourou -> TERM e KILL no grupo (neto que segura o pipe morre junto) e rc 124
ALARM_PL='my $t = shift; my $p = fork(); exit 127 unless defined $p;
if ($p == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
$SIG{ALRM} = sub { kill "TERM", -$p; select(undef, undef, undef, 0.3); kill "KILL", -$p; waitpid($p, 0); exit 124 };
alarm $t; waitpid($p, 0); my $s = $? & 127; kill "KILL", -$p; exit($s ? 128 + $s : $? >> 8);'
SEC_N=0; SEC_BAD=0; SEC_NAME=""; PROBE_RC=0; PROBE_OUT=""; PROBE_ERR=""; FILT=""
CITY_PRE="com.whatsapp com.gascity com.urblink com.athos br.urblink"
TCC_RE='(^|/)(python[0-9.]*|node|adb|dolt|gc|bd|claude|sshd|sshd-keygen-wrapper|tmux|bash|zsh|sh|cloudflared|bw|sqlite3|perl|cron|uhubctl)$|^com[.]apple[.]Terminal$|^com[.]googlecode[.]iterm2$|^com[.]google[.]Chrome$|^com[.]google[.]drivefs'
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{15,}[.][A-Za-z0-9_-]{10,}|[Bb]earer [A-Za-z0-9._~+/=-]{20,}|[A-Fa-f0-9]{40,}|[A-Za-z0-9+=_-]{60,}|(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)[A-Z0-9_]*=[^ ]{6,}|(token|secret|password|api_key)=[^ ]{6,}'

# ---- texto: só imprimível, sem crase (não rompe a cerca do markdown), linha <= 220 caracteres
clean() { tr -d '\000-\010\013-\037\177`' | cut -c1-220; }
val() { printf '%s' "$1" | clean | tr '\n' ' ' | sed 's/ *$//'; }
say() { printf '%s\n' "$*" >>"$BODY"; }
bloco() {
  local n; n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  say '```'; printf '%s\n' "$1" | head -n 40 | clean >>"$BODY"
  [ "$n" -gt 40 ] && say "(+$((n - 40)) linhas omitidas)"
  say '```'
}
fim() { [ "$SEC_N" -gt 0 ] && printf '%s\t%s\t%s\n' "$SEC_N" "$SEC_NAME" "$([ "$SEC_BAD" = 0 ] && echo ok || echo "parcial: $SEC_BAD não apurado(s)")" >>"$SUMM"; SEC_BAD=0; }
sec() { fim; SEC_N=$((SEC_N + 1)); SEC_NAME="$1"; say ""; say "## $SEC_N. $1"; say ""; }
nao() { SEC_BAD=$((SEC_BAD + 1)); say "- **não apurado**: $1"; }
# nomatch <padrão> <1º resultado do glob>: 0 = o glob não casou nada (devolveu o próprio padrão e nenhum arquivo tem esse nome). Casou = «não vazio», mesmo que o 1º nome seja link quebrado ou a pasta só tenha r-- (o -e dele falharia)
nomatch() { [ "$2" = "$1" ] && [ ! -e "$2" ]; }
# pl_nao <o que fica incompleto>: a leitura dos plists foi parcial? 0 = sim (já contou o «não apurado» com o motivo); 1 = não (pasta lida e todos os plists lidos, ou pasta sem plist)
pl_nao() {
  if [ "$PL_STATE" = nao ]; then nao "plists (~/Library/LaunchAgents): $PL_WHY; $1"
  elif [ "$PL_FULL" != 1 ]; then nao "só $PL_LIDOS de $PL_TOTAL plists foram lidos; $1"
  else return 1; fi
}

# ---- UMA sonda. PROBE_RC: 0 respondeu · 127 comando ausente · 124 estourou o prazo · 125 acabou o orçamento · outro = rc do comando.
# vazio → PROBE_OUT="" com rc 0 (quem chama diz «nenhum»); falhou/ausente/prazo → rc ≠ 0 (quem chama diz «não apurado», nunca «nenhum»)
probe() {
  local want="$1" left; shift
  PROBE_OUT=""; PROBE_ERR=""
  if ! command -v "$1" >/dev/null 2>&1; then PROBE_RC=127; PROBE_ERR="$1 não está no PATH"; return 0; fi
  left=$((BUDGET - SECONDS))
  if [ "$left" -le 0 ]; then PROBE_RC=125; PROBE_ERR="orçamento de ${BUDGET}s esgotado"; return 0; fi
  [ "$want" -gt "$PMAX" ] && want=$PMAX; [ "$want" -gt "$left" ] && want=$left
  if [ "$HAVE_PERL" = 1 ]; then
    PROBE_OUT=$(perl -e "$ALARM_PL" "$want" "$@" 2>"$WORK/err" </dev/null); PROBE_RC=$?
  else
    PROBE_OUT=$("$@" 2>"$WORK/err" </dev/null); PROBE_RC=$?
  fi
  PROBE_ERR=$(head -n 1 "$WORK/err" | clean)
  return 0
}
why() { case "$PROBE_RC" in (127) printf '%s ausente nesta máquina' "$1" ;; (124) printf '%s estourou o prazo' "$1" ;; (125) printf '%s' "$PROBE_ERR" ;; (*) printf '%s falhou (rc=%s%s)' "$1" "$PROBE_RC" "${PROBE_ERR:+: $PROBE_ERR}" ;; esac; }
# kvp <rótulo> <prazo> <cmd...>: uma linha «rótulo: valor». vazio → «nenhum»; falhou/ausente → «não apurado»
kvp() {
  local label="$1" t="$2"; shift 2; probe "$t" "$@"
  if [ "$PROBE_RC" != 0 ]; then nao "$label: $(why "$1")"
  elif [ -z "$PROBE_OUT" ]; then say "- $label: nenhum (o comando respondeu vazio)"
  else say "- $label: \`$(val "$PROBE_OUT")\`"; fi
}
# lista <rótulo> <prazo> <cmd...>: a saída inteira num bloco. vazio → «nenhum»; falhou/ausente → «não apurado»
lista() {
  local label="$1" t="$2"; shift 2; probe "$t" "$@"
  if [ "$PROBE_RC" != 0 ]; then nao "$label: $(why "$1")"
  elif [ -z "$PROBE_OUT" ]; then say "- $label: nenhum (o comando respondeu vazio)"
  else say "- $label:"; bloco "$PROBE_OUT"; fi
}
# filtra <ere>: FILT = linhas de PROBE_OUT que casam. Resposta sem NENHUMA linha reconhecível = formato inesperado (quem chama diz «não apurado»)
filtra() { FILT=$(printf '%s\n' "$PROBE_OUT" | grep -E "$1"); [ -n "$FILT" ]; }
# ldis <domínio> <arquivo>: DIS_OK=1 e os rótulos desabilitados (override do launchctl) no arquivo; DIS_OK=0 se não respondeu ou veio fora do formato
ldis() {
  DIS_OK=0; : >"$2"; probe 10 launchctl print-disabled "$1"
  if [ "$PROBE_RC" != 0 ]; then nao "launchctl print-disabled $1: $(why launchctl)"; return; fi
  if ! filtra 'disabled services|=> *(enabled|disabled|true|false)'; then nao "launchctl print-disabled $1: formato inesperado"; return; fi
  printf '%s\n' "$PROBE_OUT" | awk '/=> *(disabled|true)/ { gsub(/"/, "", $1); print $1 }' >"$2"; DIS_OK=1
}
# um awk só para todos os plists: arquivo, Label, Disabled, 3 primeiros ProgramArguments, binário? (binário = só o nome do arquivo)
# vazio → PL_STATE=vazio (a pasta existe sem *.plist); falhou/ilegível → PL_STATE=nao (pasta ausente/sem leitura) ou ok com PL_LIDOS < PL_TOTAL
scan_plists() {
  local dir="$H/Library/LaunchAgents"; PL_STATE=nao; PL_WHY=""; PL_TOTAL=0; PL_LIDOS=0; PL_FULL=0
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then PL_WHY="$dir ausente ou sem leitura"; return; fi
  set -- "$dir"/*.plist
  if nomatch "$dir/*.plist" "$1"; then PL_STATE=vazio; PL_FULL=1; return; fi
  PL_TOTAL=$#
  awk -v RS='<' '
    function out() { if (f != "") printf "%s\t%s\t%d\t%s\t%s\t%s\t%d\n", f, (l == "" ? substr(f, 1, length(f) - 6) : l), d, a[1], a[2], a[3], b }
    FNR == 1 { out(); f = FILENAME; sub(/.*\//, "", f); l = ""; d = 0; na = 0; pa = 0; dep = 0; key = ""; a[1] = a[2] = a[3] = ""; b = ($0 ~ /^bplist/) }
    /^dict>/ { dep++; next }
    /^\/dict>/ { dep--; next }
    /^key>/ { key = substr($0, 5); sub(/[ \t\r\n]+$/, "", key); next }
    /^array>/ { if (dep == 1 && key == "ProgramArguments") pa = 1; next }
    /^\/array>/ { pa = 0; next }
    /^true\/>/ { if (dep == 1 && key == "Disabled") d = 1; next }
    /^string>/ { v = substr($0, 8); sub(/[ \t\r\n]+$/, "", v); if (pa) { na++; if (na <= 3) a[na] = v } else if (dep == 1 && key == "Label") l = v; next }
    END { out() }' "$@" >"$PL" 2>/dev/null
  PL_LIDOS=$(wc -l <"$PL" | tr -d ' '); PL_STATE=ok; [ "$PL_LIDOS" -ge "$PL_TOTAL" ] && PL_FULL=1
}

# =================================================================== seções
scan_plists
# CLT primeiro e sem escrever nada: a seção 2 não roda o python3 do PATH se ele for o shim /usr/bin/python3 sem CLT confirmadas (abriria o instalador gráfico); a seção 3 mostra o resultado
probe 8 pkgutil --pkg-info=com.apple.pkg.CLTools_Executables; PK_RC=$PROBE_RC; PK_OUT=$PROBE_OUT; PK_ERR=$PROBE_ERR
sec "Máquina e rede"
kvp "sessão do launchd (Aqua = Terminal do usuário; Background = tmux do gc, onde Keychain e TCC podem responder diferente)" 5 launchctl managername
kvp "hostname" 5 hostname; HOSTN="$PROBE_OUT"
for k in ComputerName LocalHostName HostName; do
  # vazio → «não definido» (o scutil responde rc 1 «not set»: é resposta); falhou/ausente → não apurado
  probe 5 scutil --get "$k"
  if [ "$PROBE_RC" = 0 ]; then say "- $k: \`$(val "$PROBE_OUT")\`"; case "$k" in (ComputerName) CN="$PROBE_OUT" ;; (LocalHostName) LH="$PROBE_OUT" ;; esac
  elif [ "$PROBE_RC" = 1 ] && printf '%s' "$PROBE_ERR" | grep -qi 'not set'; then say "- $k: (não definido)"
  else nao "scutil --get $k: $(why scutil)"; fi
done
kvp "macOS" 5 sw_vers
kvp "modelo · chip · RAM (bytes)" 5 sysctl -n hw.model machdep.cpu.brand_string hw.memsize
kvp "arquitetura" 5 uname -m
kvp "disco dos dados" 5 df -h /System/Volumes/Data
probe 8 networksetup -listallhardwareports; HWP=""
if [ "$PROBE_RC" != 0 ]; then nao "networksetup -listallhardwareports: $(why networksetup)"
elif ! filtra '^(Hardware Port|Device|Ethernet Address)'; then nao "networksetup -listallhardwareports: formato inesperado"
else say "- portas de rede (nome · dispositivo · MAC; o MAC é o que vai na reserva DHCP do roteador):"; bloco "$FILT"; HWP="$FILT"; fi
IPERR=0
for ifn in en0 en1 en2 en3; do
  # vazio → «sem IPv4» (rc 1 sem mensagem é resposta); falhou/ausente → não apurado e para
  probe 5 ipconfig getifaddr "$ifn"
  if [ "$PROBE_RC" = 0 ] && [ -n "$PROBE_OUT" ]; then say "- IPv4 de $ifn: \`$(val "$PROBE_OUT")\`"; [ -n "${LANIP:-}" ] || { LANIP="$PROBE_OUT"; LANIF="$ifn"; }
  elif [ "$PROBE_RC" = 1 ] && [ -z "$PROBE_ERR" ]; then say "- $ifn: sem IPv4"
  else nao "ipconfig getifaddr $ifn: $(why ipconfig)"; IPERR=1; break; fi
done
# o MAC da reserva DHCP é o da interface que deu o IP (não o do en0 por palpite). vazio → sem IP em en0..en3 ou interface fora da lista = não apurado (o item 2 do checklist mostra «?»); falhou → o nao acima
if [ -n "${LANIP:-}" ]; then
  MAC=$(printf '%s\n' "$HWP" | awk -v d="Device: $LANIF" '/^Hardware Port/ { f = 0 } $0 == d { f = 1 } f && /^Ethernet Address/ { print $3; exit }')
  [ -n "$MAC" ] || nao "MAC de $LANIF: não achei na lista de portas de rede (a lista falhou ou não traz o dispositivo); o item 2 do checklist fica sem MAC"
elif [ "$IPERR" = 0 ]; then nao "IP de LAN: nenhuma interface de en0 a en3 tem IPv4; o item 2 do checklist fica sem IP"; fi
probe 8 networksetup -listallnetworkservices
if [ "$PROBE_RC" != 0 ]; then nao "networksetup -listallnetworkservices: $(why networksetup)"; else
  printf '%s\n' "$PROBE_OUT" | grep -vE '^(An asterisk|[*])' >"$WORK/svcs.all"; head -n 4 "$WORK/svcs.all" >"$WORK/svcs"
  while IFS= read -r svc; do
    # vazio → resposta sem nenhuma linha de configuração reconhecível = formato inesperado (não apurado); falhou → não apurado
    probe 8 networksetup -getinfo "$svc"; gi=$(printf '%s\n' "$PROBE_OUT" | grep -E '^(DHCP Configuration|Manual Configuration|IP address|Router)' | tr '\n' ';' | clean)
    if [ "$PROBE_RC" != 0 ]; then nao "networksetup -getinfo $(val "$svc"): $(why networksetup)"
    elif [ -z "$gi" ]; then nao "networksetup -getinfo $(val "$svc"): formato inesperado"
    else say "- serviço \`$(val "$svc")\`: $gi"; fi
  done <"$WORK/svcs"
  ns=$(wc -l <"$WORK/svcs.all" | tr -d ' '); [ "$ns" -gt 4 ] && say "- (+$((ns - 4)) serviços de rede não consultados; só os 4 primeiros)"
fi

sec "TCC e Acesso Total ao Disco"
say "Binários e apps que a cidade usa (caminho · versão); no mini novo cada um precisa das permissões da tabela mais abaixo:"; say ""
for pair in python3:--version node:--version adb:version dolt:version gc:version bd:--version claude:--version tmux:-V; do
  b="${pair%%:*}"; vf="${pair#*:}"; p=$(command -v "$b" 2>/dev/null)
  # vazio → «não achado no PATH» (≠ «não existe na máquina»: conta como não apurado); falhou → versão não apurada, caminho mantido
  if [ -z "$p" ]; then nao "$b: não achado no PATH desta sessão (confira à mão onde ele está)"; continue; fi
  if [ "$b" = python3 ] && [ "$p" = "$R/usr/bin/python3" ] && [ "$PK_RC" != 0 ]; then say "- $b → \`$(val "$p")\` · versão não executada (é o shim do sistema e as CLT não estão confirmadas: abriria o instalador gráfico)"; SEC_BAD=$((SEC_BAD + 1)); continue; fi
  probe 8 "$p" "$vf"
  if [ "$PROBE_RC" = 0 ]; then say "- $b → \`$(val "$p")\` · $(val "$(printf '%s\n' "$PROBE_OUT" | head -n 1)")"
  else say "- $b → \`$(val "$p")\` · versão não apurada ($(why "$b"))"; SEC_BAD=$((SEC_BAD + 1)); fi
done
if [ -x "$R/usr/sbin/sshd" ]; then say "- sshd → /usr/sbin/sshd (do sistema; o TCC dele aparece como sshd ou sshd-keygen-wrapper)"; else nao "sshd: /usr/sbin/sshd não existe"; fi
for app in "$R/System/Applications/Utilities/Terminal.app" "$R/Applications/iTerm.app"; do
  if [ ! -d "$app" ]; then say "- $(basename "$app"): não instalado ($app não existe)"; continue; fi
  probe 5 defaults read "$app/Contents/Info" CFBundleShortVersionString
  if [ "$PROBE_RC" = 0 ]; then say "- $(basename "$app") \`$(val "$PROBE_OUT")\`"; else nao "$(basename "$app"): versão $(why defaults)"; fi
done
say ""; say "Concessões já dadas (auth_value=2 no TCC.db; só linhas de binário ou app da cidade):"
for db in "$H/Library/Application Support/com.apple.TCC/TCC.db" "$R/Library/Application Support/com.apple.TCC/TCC.db"; do
  # vazio → «nenhuma concessão da cidade» (o banco abriu e respondeu); falhou → não apurado (motivo comum: este processo sem Acesso Total ao Disco)
  probe 10 sqlite3 -readonly -separator '|' "$db" "select service,client,auth_value from access where auth_value=2;"
  if [ "$PROBE_RC" != 0 ]; then nao "$(val "$db"): $(why sqlite3). Sem Acesso Total ao Disco este processo não lê o TCC.db: abra Ajustes ▸ Privacidade e Segurança ▸ Acesso Total ao Disco e anote a lista à mão"; continue; fi
  printf '%s\n' "$PROBE_OUT" | awk -F'|' -v re="$TCC_RE" '
    BEGIN { n = split("kTCCServiceSystemPolicyAllFiles=Acesso Total ao Disco;kTCCServiceAccessibility=Acessibilidade;kTCCServiceScreenCapture=Gravação de Tela;kTCCServiceAppleEvents=Automação;kTCCServicePostEvent=Enviar teclas;kTCCServiceListenEvent=Monitorar entrada", kv, ";"); for (i = 1; i <= n; i++) { split(kv[i], p, "="); nm[p[1]] = p[2] } }
    $2 ~ re { print "- " (($1 in nm) ? nm[$1] : $1) " · " $2; c++; next }
    NF { o++ }
    END { print "#" c + 0 " " o + 0 }' >"$WORK/tcc.out"
  cnt=$(grep '^#' "$WORK/tcc.out"); c="${cnt#\#}"; c="${c%% *}"; o="${cnt##* }"
  case "$c$o" in (''|*[!0-9]*) nao "$(val "$db"): não consegui contar as concessões (awk)"; continue ;; esac
  say "- $(val "$db") — $c da cidade, $o de outros apps (não listados):"; [ "$c" -gt 0 ] && bloco "$(grep -v '^#' "$WORK/tcc.out")"
done

sec "Command Line Tools e Python"
PROBE_RC=$PK_RC; PROBE_OUT=$PK_OUT; PROBE_ERR=$PK_ERR   # o resultado do pkgutil lido antes da seção 1
if [ "$PROBE_RC" = 0 ]; then CLTV=$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^version: //p'); say "- Command Line Tools: \`$(val "$CLTV")\`"
elif [ "$PROBE_RC" = 1 ] && printf '%s' "$PROBE_ERR" | grep -qi 'no receipt'; then CLTV="não instalado"; say "- Command Line Tools: não instalados (pkgutil: sem recibo)"
else CLTV="?"; nao "Command Line Tools: $(why pkgutil)"; fi
kvp "xcode-select -p" 5 xcode-select -p
pl_nao "a lista de pythons e de wrappers dos plists está incompleta"
# pythons: os de sempre + os caminhos absolutos que os plists citam; /usr/bin/python3 NUNCA roda sem CLT confirmadas, nem se um plist o citar (o shim abriria o instalador gráfico)
pyall=$(awk -F'\t' '{ for (i = 4; i <= 6; i++) if ($i ~ /^\/.*python/) print $i }' "$PL" | sort | uniq -c | sort -rn); pyd=$(printf '%s\n' "$pyall" | head -n 10)
pys="$R/Library/Developer/CommandLineTools/usr/bin/python3 $R/opt/homebrew/bin/python3 $R/usr/local/bin/python3"
CLT_OK=0; if [ "$CLTV" != "não instalado" ] && [ "$CLTV" != "?" ] && [ -n "${CLTV:-}" ]; then CLT_OK=1; pys="$pys $R/usr/bin/python3"; fi
CLT_PY="?"; say "- pythons (caminho · versão · plists que o citam direto):"
for p in $(printf '%s\n' $pys $(printf '%s\n' "$pyd" | awk '{ print $2 }') | sort -u | head -n 14); do
  if [ "$p" = "$R/usr/bin/python3" ] && [ "$CLT_OK" != 1 ]; then say "  - \`$(val "$p")\`: não executado (sem CLT confirmadas o shim abriria o instalador gráfico)"; continue; fi
  [ -x "$p" ] || { say "  - \`$(val "$p")\`: não existe nesta máquina"; continue; }
  probe 8 "$p" --version; n=$(printf '%s\n' "$pyd" | awk -v p="$p" '$2 == p { print $1 }')
  if [ "$PROBE_RC" = 0 ]; then say "  - \`$(val "$p")\` · $(val "$PROBE_OUT") · ${n:-0} plist(s)"; case "$p" in (*/Library/Developer/*) CLT_PY="$PROBE_OUT" ;; esac
  else nao "$(val "$p") --version: $(why python)"; fi
done
npy=$(printf '%s\n' "$pyall" | grep -c .); [ "$npy" -gt 10 ] && say "  - (+$((npy - 10)) caminhos de python citados pelos plists não listados; só os 10 mais citados)"
bare=$(awk -F'\t' '{ for (i = 4; i <= 6; i++) if ($i ~ /^python[0-9.]*$/) print $i }' "$PL" | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')
if [ "$PL_FULL" = 1 ]; then bare="${bare:-nenhum}"; else bare="não apurado (nem todos os plists foram lidos)${bare:+; nos lidos: $bare}"; fi
say "- plists que chamam python SEM caminho (o PATH do launchd decide, em geral /usr/bin/python3 = o das CLT): $bare"
awk -F'\t' '{ for (i = 4; i <= 6; i++) if ($i ~ /^\// && ($i ~ /[.](sh|py)$/ || $i ~ /wrapper/)) print $i }' "$PL" | sort -u >"$WORK/wr.all"
: >"$WORK/wrappers.lst"; wmiss=0
while IFS= read -r w; do if [ -f "$w" ]; then printf '%s\n' "$w" >>"$WORK/wrappers.lst"; else wmiss=$((wmiss + 1)); fi; done <"$WORK/wr.all"
if [ -s "$WORK/wrappers.lst" ]; then
  # vazio → «nenhum» (grep rc 1); falhou (rc ≥ 2: algum wrapper ilegível) → não apurado e a lista fica marcada como parcial
  probe 25 grep -hoE '/[^ "$()]*python[0-9.]*' $(cat "$WORK/wrappers.lst")
  wp=$(printf '%s\n' "$PROBE_OUT" | sort | uniq -c | sort -rn | sed 's/^ *//')
  if [ "$PROBE_RC" -gt 1 ]; then nao "wrappers dos plists: $(why grep); a lista abaixo é parcial"; else wp="${wp:-(nenhum)}"; fi
  say "- caminhos de python citados dentro dos wrappers dos plists ($(wc -l <"$WORK/wrappers.lst" | tr -d ' ') lidos, $wmiss citados e ausentes; texto, não resolvido):"; bloco "${wp:-(nada lido)}"
elif [ "$wmiss" -gt 0 ]; then say "- wrappers dos plists: 0 lidos, $wmiss citados e ausentes (não há o que ler)"
fi

sec "Drivers de sistema (WCH.CN das placas)"
probe 15 systemextensionsctl list
if [ "$PROBE_RC" != 0 ]; then nao "systemextensionsctl list: $(why systemextensionsctl)"
elif ! filtra 'extension[(]s[)]|^---|activated'; then nao "systemextensionsctl list: formato inesperado"
else w=$(printf '%s\n' "$PROBE_OUT" | grep -iE 'wch|ch34|ch910'); if [ -n "$w" ]; then say "- extensões de sistema da WCH:"; bloco "$w"; else say "- extensões de sistema: nenhuma da WCH entre as listadas (apurado)"; fi; fi
probe 15 kextstat
if [ "$PROBE_RC" != 0 ]; then nao "kextstat: $(why kextstat)"
elif [ -z "$PROBE_OUT" ]; then nao "kextstat: respondeu vazio (o esperado é ao menos o cabeçalho); não vale como «nenhum kext»"
else w=$(printf '%s\n' "$PROBE_OUT" | grep -iE 'wch|ch34|ch910'); if [ -n "$w" ]; then say "- kexts da WCH:"; bloco "$w"; else say "- kexts: nenhum da WCH entre os carregados (apurado)"; fi; fi
set -- "$R"/dev/cu.*
if ! nomatch "$R/dev/cu.*" "$1"; then say "- portas seriais (/dev/cu.*, só nomes):"; bloco "$(printf '%s\n' "$@" | sed 's#.*/##')"; else say "- portas seriais (/dev/cu.*): nenhuma (o /dev respondeu e não tem cu.*)"; fi

sec "Placas USB e celulares (A03)"
probe 40 system_profiler SPUSBDataType
if [ "$PROBE_RC" != 0 ]; then nao "system_profiler SPUSBDataType: $(why system_profiler)"
elif ! filtra 'Vendor ID:|USB'; then nao "system_profiler SPUSBDataType: formato inesperado"
else
  usb=$(printf '%s\n' "$PROBE_OUT" | awk '
    function flush() { if (nm != "" && (vid != "" || pid != "")) print nm " | vendor " vid " | produto " pid " | serial " (sn == "" ? "-" : sn); nm = ""; vid = ""; pid = ""; sn = "" }
    /^ +[^ :][^:]*:$/ { flush(); nm = $0; sub(/^ +/, "", nm); sub(/:$/, "", nm); next }
    /Product ID:/ { pid = $NF }
    /Vendor ID:/ { vid = $3 }
    /Serial Number:/ { sn = $NF }
    END { flush() }')
  say "- dispositivos USB (nome · vendor · produto · serial; vendor 0x1a86 = WCH). Placa A03: a ordem do Athos é mantê-la DESLIGADA, então o inventário só registra e o Athos aponta qual linha é ela:"; bloco "${usb:-(nenhum dispositivo com vendor/produto no texto)}"
fi
probe 5 pgrep -x adb
if [ "$PROBE_RC" = 1 ]; then nao "celulares: o servidor adb não está rodando e o inventário não o inicia"
elif [ "$PROBE_RC" != 0 ]; then nao "celulares: $(why pgrep)"
else
  probe 10 adb devices -l
  if [ "$PROBE_RC" != 0 ]; then nao "adb devices -l: $(why adb)"
  else ph=$(printf '%s\n' "$PROBE_OUT" | awk 'NR > 1 && NF >= 2 { m = "?"; for (i = 3; i <= NF; i++) if ($i ~ /^model:/) m = substr($i, 7); print "…" substr($1, length($1) - 3) " · " $2 " · " m }')
    say "- celulares no adb ($(printf '%s\n' "$ph" | grep -c .); serial mascarado nos 4 últimos)$([ -z "$ph" ] && echo ': nenhum')"; [ -n "$ph" ] && bloco "$ph"
    # vazio → 0 aparelhos e 0 A03 (o adb respondeu só o cabeçalho); aparelho sem «model:» (unauthorized, offline) → não dá para dizer se é o A03: conta como não apurado, nunca como «0»
    nm=$(printf '%s\n' "$ph" | awk -F' · ' '$3 == "?"' | grep -c .)
    say "- A03 visível no adb: $(printf '%s\n' "$ph" | awk -F' · ' '$3 ~ /A03/' | grep -c .)$([ "$nm" -gt 0 ] && echo " (+$nm com modelo ilegível: unauthorized ou offline, não dá para dizer se é o A03)" || echo ' (o esperado é 0: a placa do A03 fica desligada)')"
    [ "$nm" -gt 0 ] && nao "A03: $nm aparelho(s) do adb sem modelo legível; a contagem de A03 é parcial"; fi
fi

sec "Chaves e hosts ssh"
lista "nomes em ~/.ssh (conteúdo de chave privada NÃO é lido)" 5 ls -1 "$H/.ssh"
for f in "$H"/.ssh/*.pub; do
  nomatch "$H/.ssh/*.pub" "$f" && continue   # nenhuma .pub: a lista de nomes acima já mostrou a pasta; link quebrado entra e falha no ssh-keygen (não apurado)
  # vazio → linha sem impressão; falhou/ilegível → não apurado
  probe 5 ssh-keygen -lf "$f"
  if [ "$PROBE_RC" = 0 ]; then say "- $(val "$(basename "$f")"): $(printf '%s\n' "$PROBE_OUT" | awk '{ print $1, $2, $NF }' | clean)"; else nao "$(val "$(basename "$f")"): $(why ssh-keygen)"; fi
done
for pair in "chaves que entram NO mini (authorized_keys; o comentário diz de qual máquina):$H/.ssh/authorized_keys" "hosts em que o mini confia (known_hosts; entradas com hash não têm nome):$H/.ssh/known_hosts"; do
  # vazio → «0 entrada(s)»; arquivo ausente/ilegível → não apurado
  if [ ! -r "${pair#*:}" ]; then nao "${pair%%:*}: ${pair#*:} ausente ou sem leitura"; continue; fi
  probe 10 ssh-keygen -lf "${pair#*:}"
  if [ "$PROBE_RC" != 0 ]; then nao "${pair%%:*}: $(why ssh-keygen)"; else say "- ${pair%%:*}: $(printf '%s\n' "$PROBE_OUT" | grep -c .) entrada(s)"; bloco "$(printf '%s\n' "$PROBE_OUT" | awk '{ print $1, $2, $3, $NF }')"; fi
done
set -- "$R"/etc/ssh/ssh_host_*_key.pub
if [ ! -e "$1" ]; then nao "chaves de host do sshd: /etc/ssh/ssh_host_*_key.pub ausente ou sem leitura"; else
  for f in "$@"; do probe 5 ssh-keygen -lf "$f"
    if [ "$PROBE_RC" = 0 ]; then say "- chave de host $(val "$(basename "$f")"): $(printf '%s\n' "$PROBE_OUT" | awk '{ print $1, $2, $NF }' | clean) (é isto que o known_hosts de MBP, Hetzner e GCP guarda)"; else nao "$(val "$(basename "$f")"): $(why ssh-keygen)"; fi; done
fi
# vazio → «nenhuma linha dessas chaves» (grep rc 1); falhou/ilegível → não apurado. Só Host/HostName/Port/User/IdentityFile (ProxyCommand e afins não são copiados)
if [ ! -r "$H/.ssh/config" ]; then nao "~/.ssh/config ausente ou sem leitura"; else
  probe 5 grep -iE '^[[:space:]]*(Host|HostName|Port|User|IdentityFile)[[:space:]]' "$H/.ssh/config"
  if [ "$PROBE_RC" -le 1 ]; then say "- ~/.ssh/config (Host · HostName · Port · User · IdentityFile):"; bloco "${PROBE_OUT:-(nenhuma linha dessas chaves)}"; else nao "~/.ssh/config: $(why grep)"; fi
fi
kvp "Login remoto (systemsetup precisa de admin; sem ele isto sai não apurado)" 5 systemsetup -getremotelogin

sec "LaunchAgents do usuário (~/Library/LaunchAgents)"
case "$PL_STATE" in
  (nao) pl_nao "sem tabela de prefixos" ;;
  (vazio) say "- nenhum *.plist (a pasta existe e está vazia)" ;;
  (*)
    pl_nao "os não lidos ficam fora das contas abaixo"
    ldis "gui/$(id -u)" "$WORK/dis.user"; LOD_OK=0; : >"$WORK/lod.user"
    probe 10 launchctl list
    if [ "$PROBE_RC" != 0 ]; then nao "launchctl list: $(why launchctl)"
    elif ! printf '%s\n' "$PROBE_OUT" | head -n 1 | grep -q '^PID'; then nao "launchctl list: formato inesperado"
    else printf '%s\n' "$PROBE_OUT" | awk -F'\t' 'NR > 1 { print $3 }' >"$WORK/lod.user"; LOD_OK=1; fi
    say "- $PL_LIDOS plists lidos ($(awk -F'\t' '$7 == 1' "$PL" | wc -l | tr -d ' ') em formato binário: só o nome do arquivo). Prefixos da cidade levam *; «desabilitados» = override do launchctl; «Disabled» = chave no plist."
    say ""; say "| prefixo | plists | desabilitados | carregados | Disabled no arquivo |"; say "|---|---|---|---|---|"
    awk -F'\t' -v dok="$DIS_OK" -v lok="$LOD_OK" -v city=" $CITY_PRE " '
      FILENAME == ARGV[1] { dis[$1] = 1; next }
      FILENAME == ARGV[2] { lod[$1] = 1; next }
      { n = split($2, p, "."); pre = (n >= 2 ? p[1] "." p[2] : $2); t[pre]++; if ($3 == 1) fd[pre]++; if ($2 in dis) di[pre]++; if ($2 in lod) lo[pre]++ }
      END { m = split(city, cp, " "); for (i = 1; i <= m; i++) if (!(cp[i] in t)) t[cp[i]] = 0
            for (k in t) { c = (index(city, " " k " ") > 0); printf "%d\t%s%s\t%s\t%s\t%d\t%d\n", t[k] + (c ? 1000000 : 0), k, (c ? " *" : ""), (dok ? di[k] + 0 : "?"), (lok ? lo[k] + 0 : "?"), fd[k] + 0, t[k] } }' "$WORK/dis.user" "$WORK/lod.user" "$PL" \
      | sort -rn >"$WORK/pl.tbl"   # o 1º campo ordena (prefixo da cidade primeiro, depois por nº de plists); o último é o nº de plists
    head -n 15 "$WORK/pl.tbl" | awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $2, $6, $3, $4, $5 }' | clean >>"$BODY"
    np=$(wc -l <"$WORK/pl.tbl" | tr -d ' '); [ "$np" -gt 15 ] && { say ""; say "(+$((np - 15)) prefixos omitidos; os da cidade vêm primeiro)"; }
    if [ "$DIS_OK" = 1 ]; then dl=$(awk -F'\t' 'FILENAME == ARGV[1] { dis[$1] = 1; next } $2 in dis { print $2 }' "$WORK/dis.user" "$PL" | sort)
      say ""; say "- desabilitados pelo launchctl entre os plists da pasta (até 40):"; bloco "${dl:-(nenhum)}"; fi ;;
esac

sec "LaunchDaemons do sistema e sudoers"
probe 5 ls -1 "$R/Library/LaunchDaemons"
if [ "$PROBE_RC" != 0 ]; then nao "/Library/LaunchDaemons: $(why ls)"; else cd_=$(printf '%s\n' "$PROBE_OUT" | grep -E '^(com[.](whatsapp|gascity|urblink|athos)|br[.]urblink)[.]'); say "- /Library/LaunchDaemons: $(printf '%s\n' "$PROBE_OUT" | grep -c .) plist(s), $(printf '%s\n' "$cd_" | grep -c .) com prefixo da cidade:"; bloco "${cd_:-(nenhum com prefixo da cidade)}"; fi
lista "/Library/LaunchAgents (nomes)" 5 ls -1 "$R/Library/LaunchAgents"
ldis system "$WORK/dis.system"; [ "$DIS_OK" = 1 ] && say "- desabilitados no domínio system: $(grep -c . "$WORK/dis.system")"
lista "/etc/sudoers.d (só nomes; o conteúdo NÃO é lido)" 5 ls -1 "$R/etc/sudoers.d"

sec "Homebrew"
lista "brew leaves" 40 brew leaves
lista "brew casks" 40 brew list --cask

sec "Portas em escuta (TCP)"
say "Só nome do processo e porta. Sem sudo o lsof enxerga só os processos deste usuário (daemons de root, como o sshd, ficam de fora)."
# vazio → «nenhum listener visível» (lsof rc 1 sem saída e sem erro é resposta); falhou/formato fora → não apurado
probe 20 lsof +c 0 -nP -iTCP -sTCP:LISTEN -Fcn
if [ "$PROBE_RC" = 1 ] && [ -z "$PROBE_ERR" ] && [ -z "$PROBE_OUT" ]; then say "- nenhum listener TCP visível a este usuário"
elif [ "$PROBE_RC" != 0 ]; then nao "lsof: $(why lsof)"
elif ! printf '%s\n' "$PROBE_OUT" | grep -q '^n'; then nao "lsof: saída sem nenhuma linha de porta (formato inesperado)"
else bloco "$(printf '%s\n' "$PROBE_OUT" | awk '/^c/ { c = substr($0, 2) } /^n/ { n = substr($0, 2); sub(/.*:/, "", n); print n " · " c }' | sort -n | uniq)"; fi

sec "Keychain e segredos (só NOMES, nunca valores)"
# raízes onde o código cita nomes de item: só as nomeadas aqui; todo «nenhum» abaixo diz quantas raízes candidatas não existem (não foram lidas)
NAMES_OK=0; cand="${MINI64_SCAN_ROOTS:-$CITY/scripts $CITY/packs $H/.local/bin $H/.gastown/scripts}"
if [ -z "${MINI64_SCAN_ROOTS:-}" ]; then for rig in "$H"/gt/*/; do for d in launchd daemons lib scripts bin deploy; do cand="$cand ${rig}$d"; done; done; fi
roots=""; absent=0; for r in $cand; do if [ -d "$r" ]; then roots="$roots $r"; else absent=$((absent + 1)); fi; done
NROOTS=$(printf '%s\n' $roots | grep -c .)
if [ -z "$roots" ]; then nao "nenhuma raiz de código existe; nomes de item não apurados"; else
  # vazio → «nenhum nome citado»; falhou → não apurado (grep rc ≥ 2: alguma raiz ou arquivo ilegível); a saída bruta fica só em memória
  probe 40 grep -rhIE --include='*.sh' --include='*.py' --include='*.plist' --include='*.toml' -e 'generic-password' -e 'internet-password' -e '(^|[^[:alnum:]_./-])secret[[:space:]"'"'"',]' -e 'GoogleDrive-' $roots
  if [ "$PROBE_RC" -gt 1 ]; then nao "varredura de nomes nas raízes: $(why grep)"; else NAMES_OK=1
    say "- varridas $NROOTS raízes de código ($absent candidatas ausentes, não contadas); os nomes saem do TEXTO do código e não provam que o item existe:"
    printf '%s\n' "$PROBE_OUT" | grep -E 'generic-password|internet-password' | tr "'" '"' | sed -nE 's/.*(-s[[:space:]]+|"-s",[[:space:]]*)"([^"$]+)".*/\2/p' | grep -vE '[][{}()<>]' | sort | uniq -c | sort -rn >"$WORK/svc.all"; head -n 25 "$WORK/svc.all" >"$WORK/svc.names"   # o grep -v tira o que o código MONTA (f-string {svc}, regex ([^…): fragmento não é nome de item
    printf '%s\n' "$PROBE_OUT" | tr "'" '"' | sed -nE -e 's/.*[$][(]secret[[:space:]]+"?([A-Za-z0-9][A-Za-z0-9._:@+-]*).*/\1/p' -e 's/^[[:space:]]*secret[[:space:]]+"?([A-Za-z0-9][A-Za-z0-9._:@+-]*).*/\1/p' -e 's/.*"secret",[[:space:]]*"([^"$]+)".*/\1/p' | sort | uniq -c | sort -rn | sed 's/^ *//' >"$WORK/sec.names"
    printf '%s\n' "$PROBE_OUT" | grep -oE 'GoogleDrive-[A-Za-z0-9._%+@-]+' | sort -u >"$WORK/gd.names"
  fi
fi
probe 8 security list-keychains -d user; KC_OK=0
if [ "$PROBE_RC" = 0 ] && printf '%s\n' "$PROBE_OUT" | grep -q 'login.keychain'; then KC_OK=1
else nao "Keychain: $(why security); sem o login.keychain na lista desta sessão a presença dos itens fica NÃO APURADA (rode também no Terminal do usuário)"; fi
# kc_item <serviço>: KC = presente | ausente | não apurado; KC_CLASS = classe de acesso (pdmn). Só atributos: nunca -w nem -g.
kc_item() {
  KC_CLASS=""; [ "$KC_OK" = 1 ] || { KC="não apurado (keychain desta sessão inacessível)"; SEC_BAD=$((SEC_BAD + 1)); return; }
  probe 8 security find-generic-password -s "$1"
  case "$PROBE_RC" in
    (0) KC="presente"; KC_CLASS=$(printf '%s\n' "$PROBE_OUT" | sed -n 's/.*"pdmn"<blob>="\([a-z]*\)".*/\1/p' | head -n 1) ;;
    (44) KC="ausente" ;;
    (*) KC="não apurado ($(why security))"; SEC_BAD=$((SEC_BAD + 1)) ;;
  esac
}
if [ -s "$WORK/svc.names" ]; then say "- itens do Keychain que o código cita (-s NOME; nome montado por variável fica de fora, as contas Claude estão na seção 12): referências · nome · no Keychain · classe de acesso (final «u» = ThisDeviceOnly, NÃO migra):"
  while read -r cnt nm; do kc_item "$nm"; tdo=""
    # presente sem a linha pdmn → classe desconhecida = não apurada (e conta), nunca «ThisDeviceOnly: não»
    if [ "$KC" = presente ]; then case "$KC_CLASS" in (*u) tdo=" · ThisDeviceOnly: SIM" ;; (?*) tdo=" · ThisDeviceOnly: não ($(val "$KC_CLASS"))" ;; (*) tdo=" · classe de acesso não apurada"; SEC_BAD=$((SEC_BAD + 1)) ;; esac; fi
    say "  - $cnt× \`$(val "$nm")\` · $KC$tdo"; done <"$WORK/svc.names"
  NSV=$(wc -l <"$WORK/svc.all" | tr -d ' '); [ "$NSV" -gt 25 ] && say "  - (+$((NSV - 25)) nomes omitidos; só os 25 mais citados foram consultados)"
elif [ "$NAMES_OK" = 1 ]; then say "- itens do Keychain citados no código: nenhum nas $NROOTS raízes lidas ($absent candidatas não existem e ficaram de fora)"; fi
if [ -s "$WORK/sec.names" ]; then say "- itens do cofre que o código pede ao comando secret (nomes; o cofre NÃO é consultado):"; bloco "$(cat "$WORK/sec.names")"
elif [ "$NAMES_OK" = 1 ]; then say "- nomes passados ao secret: nenhum nas $NROOTS raízes lidas ($absent candidatas não existem e ficaram de fora)"; fi

sec "Contas Claude (só quais)"
kvp "claude" 8 claude --version
say "- por pasta de conta: e-mail do perfil · .credentials.json · item do Keychain (nome derivado do caminho absoluto) · presença:"
# vazio → «nenhuma conta de pasta própria» (o ls respondeu vazio); pasta ausente ou ilegível → não apurado (o glob abaixo devolve o padrão literal nos dois casos e o laço pularia em silêncio)
if [ ! -d "$H/.gastown/claude-accounts" ]; then nao "$H/.gastown/claude-accounts não existe: as contas de pasta própria não foram listadas"
else probe 5 ls -1 "$H/.gastown/claude-accounts"
  if [ "$PROBE_RC" != 0 ]; then nao "$H/.gastown/claude-accounts: $(why ls); as contas de pasta própria não foram listadas"
  elif [ -z "$PROBE_OUT" ]; then say "- $H/.gastown/claude-accounts: nenhuma conta de pasta própria (a pasta existe e está vazia)"; fi
fi
for d in "$H/.claude" "$H/.gastown/claude-pool-cred" "$H"/.gastown/claude-accounts/*; do
  if [ ! -d "$d" ]; then case "$d" in (*/claude-accounts/\*) ;; (*) say "  - \`$(val "${d#$H/}")\`: pasta não existe (apurado)" ;; esac; continue; fi
  prof="$d/.claude.json"; svc="Claude Code-credentials"; [ "$d" = "$H/.claude" ] && prof="$H/.claude.json"
  [ "$d" = "$H/.claude" ] || { h8=$(printf '%s' "$d" | shasum -a 256 2>/dev/null | cut -c1-8); svc="Claude Code-credentials-$h8"; [ "${#h8}" = 8 ] || svc=""; }
  # vazio → «sem e-mail no perfil» (rc 1 do grep é resposta); falhou/ilegível → não apurado
  if [ ! -e "$prof" ]; then mail="sem .claude.json"; else
    probe 5 grep -m1 -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$prof"
    if [ "$PROBE_RC" = 0 ]; then mail=$(printf '%s\n' "$PROBE_OUT" | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'); elif [ "$PROBE_RC" = 1 ]; then mail="sem e-mail no perfil"; else mail="NÃO APURADO ($(why grep))"; SEC_BAD=$((SEC_BAD + 1)); fi
  fi
  if [ -z "$svc" ]; then KC="não apurado (shasum ausente)"; SEC_BAD=$((SEC_BAD + 1)); else kc_item "$svc"; fi
  cr="sem .credentials.json"; [ -e "$d/.credentials.json" ] && cr=".credentials.json existe"
  say "  - \`$(val "${d#$H/}")\` · $(val "$mail") · $cr · \`$(val "$svc")\` · $KC"
done

sec "Google Drive (File Provider)"
if [ -d "$R/Applications/Google Drive.app" ]; then kvp "Google Drive.app" 5 defaults read "$R/Applications/Google Drive.app/Contents/Info" CFBundleShortVersionString; else say "- Google Drive.app: não instalado (/Applications/Google Drive.app não existe)"; fi
probe 5 pgrep -x "Google Drive"
if [ "$PROBE_RC" = 0 ]; then say "- Google Drive: rodando"; elif [ "$PROBE_RC" = 1 ]; then say "- Google Drive: não está rodando agora"; else nao "Google Drive (processo): $(why pgrep)"; fi
probe 10 pluginkit -mA -p com.apple.fileprovider-nonui
if [ "$PROBE_RC" != 0 ]; then nao "extensões File Provider: $(why pluginkit)"; else gp=$(printf '%s\n' "$PROBE_OUT" | grep -i 'google' | head -n 5); if [ -n "$gp" ]; then say "- extensões File Provider do Google:"; bloco "$gp"; else say "- extensões File Provider do Google: nenhuma entre as listadas (apurado)"; fi; fi
if [ -s "$WORK/gd.names" ]; then say "- pontos de montagem que o código espera sob ~/Library/CloudStorage (lidos do CÓDIGO; a pasta NÃO é aberta, porque dispara o aviso de TCC):"; bloco "$(cat "$WORK/gd.names")"
# vazio → «nenhum» só se a varredura de nomes da seção 11 rodou (NAMES_OK=1); sem ela (nenhuma raiz de código, grep falhou) → não apurado, nunca «nenhum»
elif [ "$NAMES_OK" = 1 ]; then say "- pontos de montagem citados no código: nenhum encontrado nas raízes lidas"
else nao "pontos de montagem citados no código: a varredura de nomes da seção 11 não rodou ou falhou"; fi

sec "bw serve (Bitwarden)"
kvp "bw" 8 bw --version
probe 8 ps -axo command=
if [ "$PROBE_RC" != 0 ]; then nao "processos: $(why ps)"; else
  bs=$(printf '%s\n' "$PROBE_OUT" | awk '/(^|\/)bw +serve/ { p = ""; h = ""; for (i = 1; i <= NF; i++) { if ($i == "--port") p = $(i + 1); if ($i == "--hostname") h = $(i + 1) } print "bw serve --port " (p == "" ? "(padrão)" : p) " --hostname " (h == "" ? "(padrão)" : h) }')
  if [ -n "$bs" ]; then say "- rodando agora (só porta e hostname; o resto da linha de comando não é copiado):"; bloco "$bs"; else say "- nenhum «bw serve» rodando agora (ps respondeu)"; fi
fi
# vazio → «nenhum» só com TODOS os plists lidos; leitura parcial (pasta ilegível, link quebrado, plist ilegível) → «não apurado» + nao, nunca «nenhum»
bj=$(awk -F'\t' '($4 " " $5 " " $6) ~ /bw +serve/ { print $2 }' "$PL" | sort -u | tr '\n' ' ' | sed 's/ *$//')
if [ "$PL_FULL" = 1 ]; then bj="${bj:-nenhum}"; else bj="não apurado (nem todos os plists foram lidos)${bj:+; nos lidos: $bj}"; pl_nao "a lista de plists com «bw serve» direto está incompleta"; fi
say "- plists com «bw serve» direto nos argumentos: $(val "$bj")"
if [ -s "$WORK/wrappers.lst" ]; then
  # vazio → «nenhum» (grep rc 1); falhou → não apurado
  probe 25 grep -lE 'bw +serve' $(cat "$WORK/wrappers.lst")
  if [ "$PROBE_RC" -gt 1 ]; then nao "wrappers com «bw serve»: $(why grep)"; else say "- wrappers de plist que sobem «bw serve»: $(printf '%s\n' "$PROBE_OUT" | sed 's#.*/##' | head -n 10 | tr '\n' ' ')$([ -z "$PROBE_OUT" ] && echo nenhum)"; fi
fi

sec "Energia (pmset)"
lista "pmset -g custom" 8 pmset -g custom; PMSET_OUT="$PROBE_OUT"; PMSET_RC="$PROBE_RC"
lista "pmset -g sched (ligar, desligar ou acordar agendado)" 8 pmset -g sched
fim

# =================================================================== checklist (parte estática + valores deste inventário)
tk() { printf '%s' "$1" | clean | tr -c 'A-Za-z0-9._:@/+ \n\047\200-\377-' '?' | tr '\n' ' ' | sed 's/ *$//'; }   # \047 = apóstrofo (o nome do computador do macOS costuma tê-lo)
ipx=$(tk "${LANIP:-}"); lhx=$(tk "${LH:-}")   # o marcador <…> do item 7 não passa pelo tk (ele o trocaria por «?»)
{
  say ""; say "## Checklist: o que refazer à mão no mini novo"; say ""
  say "Nada daqui roda sozinho: a ordem de carga e a chave de espera são das fatias .2 e .5. Marque um item só depois de ver no mini novo o MESMO valor que este inventário mostra."; say ""
  say "1. [ ] Nome: Ajustes do Sistema ▸ Geral ▸ Compartilhamento ▸ Nome do computador = «$(tk "${CN:-?}")» e Nome do host local = «$(tk "${LH:-?}")»."
  say "2. [ ] IP de LAN: no roteador, mover a reserva DHCP de $(tk "${LANIP:-?}") (MAC atual $(tk "${MAC:-?}")) para o MAC do mini novo (Ajustes ▸ Rede ▸ Ethernet ▸ Detalhes ▸ Hardware)."
  say "3. [ ] Energia, no Terminal do mini novo (valores do mini atual):"
  pm=$(printf '%s\n' "$PMSET_OUT" | awk '/^AC Power:/ { ac = 1; next } /^[A-Za-z].*:$/ { ac = 0 } ac && $1 ~ /^(sleep|displaysleep|disksleep|womp|autorestart|powernap|standby|ttyskeepawake|tcpkeepalive)$/ && $2 ~ /^[0-9]+$/ { print "   - `sudo pmset -c " $1 " " $2 "`" }')
  if [ "$PMSET_RC" != 0 ]; then say "   - não apurado: o pmset -g custom falhou, anote os valores à mão no mini atual"; else say "${pm:-   - o pmset -g custom não trouxe nenhuma das chaves conhecidas; confira à mão}"; fi
  say "4. [ ] Command Line Tools: Terminal ▸ \`xcode-select --install\` ▸ Instalar. Depois \`python3 --version\` deve dar «$(tk "${CLT_PY:-?}")» (CLT do mini atual: $(tk "${CLTV:-?}"))."
  say "5. [ ] Acesso Total ao Disco: Ajustes ▸ Privacidade e Segurança ▸ Acesso Total ao Disco ▸ + ▸ ⌘⇧G ▸ colar o caminho ▸ Abrir, para CADA binário da seção TCC (python3, node, adb, dolt, gc, bd, claude, tmux, sshd, Terminal/iTerm). Repetir em Automação, Acessibilidade e Gravação de Tela se a tabela listar."
  say "6. [ ] Driver WCH.CN: instalar o driver serial da WCH (pacote do fabricante), Ajustes ▸ Privacidade e Segurança ▸ Permitir a extensão ▸ reiniciar; com as placas ligadas (a do A03 NÃO), \`ls /dev/cu.wchusbserial*\` tem de listar as portas da seção Drivers."
  say "7. [ ] Chaves de host do ssh: as impressões estão na seção ssh. Ou copiar /etc/ssh/ssh_host_* do mini atual para o novo (sudo, dono root, 600 nas privadas, depois reiniciar o sshd) ANTES do corte, ou em MBP, Hetzner e GCP rodar \`ssh-keygen -R ${ipx:-<IP do mini>}\` e \`ssh-keygen -R ${lhx:-<nome do mini>}.local\` (e o nome ou porta que cada um usa) e aceitar a chave nova."
  say "8. [ ] LaunchDaemons e sudoers: recriar os arquivos que a seção LaunchDaemons lista, dono root:wheel, e só carregar na ordem da fatia .2 (o conteúdo de sudoers.d NÃO foi lido: copiar do mini atual com visudo -c)."
  say "9. [ ] Keychain: para cada item «ausente» da seção Keychain refazer a gravação; os «ThisDeviceOnly: SIM» NÃO migram nem com o Assistente."
  say "10. [ ] A03: a placa do A03 continua DESLIGADA no mini novo; só religar com ordem do Athos (bead ga-ke5w2ie.15)."
  say "11. [ ] bw serve: \`bw login\` e \`bw unlock\` no mini novo; recarregar o job que sobe o serve na porta da seção bw serve (depois da chave de espera)."
  say "12. [ ] Contas Claude: para cada pasta da seção Contas Claude, \`claude auth login --email <e-mail da linha>\` com CLAUDE_CONFIG_DIR apontando para a pasta; conferir que o item do Keychain da linha ficou «presente»."
  say "13. [ ] Google Drive: instalar o Google Drive para computador, entrar com a conta do código, Ajustes ▸ Privacidade e Segurança ▸ Arquivos e Pastas ▸ conferir o acesso; o ponto de montagem em ~/Library/CloudStorage tem de ter o mesmo nome da seção Google Drive."
}

# =================================================================== montagem: Resumo + Contents + varredura de segredo + gravação atômica
ALL="$WORK/all.md"
{ printf '\n## Resumo\n\n| seção | estado |\n|---|---|\n'; awk -F'\t' '{ printf "| %s. %s | %s |\n", $1, $2, $3 }' "$SUMM"; cat "$BODY"; } >"$ALL" \
  || { echo "inventario: não consegui montar o corpo do doc" >&2; exit 1; }
N_SEC=$(grep -c '^## ' "$ALL")
# vazio → 0 linhas suspeitas (grep rc 1); falhou (rc ≥ 2) → NÃO grava: um doc sem varredura pode vazar segredo
HITS=$(grep -cE -e "$SECRET_RE" "$ALL"); rc=$?
case "$rc" in (0|1) ;; (*) echo "inventario: não consegui varrer o doc atrás de segredo (grep rc=$rc); nada foi escrito" >&2; exit 1 ;; esac
FINAL="$WORK/final.md"
{
  printf '# Mini 64: inventário de dependências de máquina\n\n'
  printf 'Gerado por scripts/mini64/inventario.sh em %s UTC no host %s, SÓ LEITURA. «não apurado» = a sonda não conseguiu responder (e a seção diz por quê); «nenhum» = respondeu vazio. %s linha(s) com cara de segredo foram suprimidas. Rode de novo quando a máquina mudar.\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(tk "${HOSTN:-?}")" "$HITS"
  printf '## Contents\n\n'; grep '^## ' "$ALL" | sed 's/^## /• /'; printf '\n'
  sed -E "s#$SECRET_RE#[suprimido]#g" "$ALL"
} >"$FINAL" || { echo "inventario: não consegui montar o doc" >&2; exit 1; }
mv "$FINAL" "$DOC" || { echo "inventario: não consegui gravar $DOC" >&2; exit 1; }
echo "inventario: $N_SEC seções, $HITS linha(s) suprimida(s), $(awk -F'\t' '$3 != "ok"' "$SUMM" | wc -l | tr -d ' ') com algo não apurado -> $DOC"
exit 0
