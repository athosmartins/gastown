#!/usr/bin/env bash
# go-nogo.sh (ga-ke5w2ie.3) — UM comando que diz GO / NO-GO / INCERTO para seguir com o mini 64 na noite do corte (prazo 04:30).
#
# ## Contents
#   O que faz · Saída · Variáveis · Teste
#
# O QUE FAZ  Risco 5 do épico ga-ke5w2ie: o rollback real só existe até o 1º envio no 64, então a decisão pede um veredito único e um horário-limite. Roda as checagens (uma linha cada), SÓ LÊ (nada é carregado, parado,
#   gravado nem enviado) e fecha com o veredito. dolt-porta (porta viva lida do processo, scripts/dolt-pid-lib.sh, nunca de arquivo) · bd-<nome> (bd list rápido em cada banco) · supervisor, pilot, gate (launchd) · gc ·
#   imparavel (o VEREDITO do imparavel-check.py) · painel-<nome> (curl nas linhas de paineis.tsv; vale 200/401/403) · adb (seriais de celulares.tsv) · cloudflared-job e cloudflared-conectores (exatamente 1) · disco · swap ·
#   espera (o marcador da fatia .2 no estado esperado, --espera) · envio (com a espera ligada o central-sender NÃO está carregado).
# SAÍDA  [OK]/[NO-GO]/[INCERTO] por checagem e, na ÚLTIMA linha, VEREDITO: GO (exit 0) | NO-GO (1) | INCERTO (2); 64 = uso errado. NO-GO = falha CONFIRMADA; INCERTO = leitura sem resposta (comando ausente, estouro,
#   saída ilegível) e nunca conta como GO; falha e incerto juntos = NO-GO. Cada checagem tem prazo de no máximo 20 s, do próprio script (sem `timeout` do sistema). O que fazer em cada veredito: docs/runbooks/mini64/03-go-nogo.md
# VARIÁVEIS  GC_CITY_PATH · CLOUDFLARED_CONFIG · GONOGO_{BD_STORES,IMPARAVEL,PAINEIS,CELULARES,TIMEOUT,BD_SLOW_S,HTTP_OK,DISCO_MIN_MB,SWAP_MAX_MB,VOLUME,ESPERA_MARCADOR,PRAZO,EXTRA_PATH,LABEL_*} (runbook, "Ensaio")
# TESTE  bash scripts/mini64/go-nogo.selftest.sh
set -u
case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
HERE="$(cd "$_d" && pwd)"; TAB="$(printf '\t')"
# PATH: ssh e launchd entregam um PATH mínimo, o terminal do mini tem /opt/homebrew/bin. Acrescenta no FIM (nunca antes); GONOGO_EXTRA_PATH="" desliga (selftest).
_x="${GONOGO_EXTRA_PATH-/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin}"
[ -z "$_x" ] || PATH="${PATH:+$PATH:}$_x"
export PATH
CITY="${GC_CITY_PATH:-$(cd "$HERE/../.." && pwd)}"; export GC_CITY="$CITY" GC_CITY_PATH="$CITY"
unset GC_DOLT_PORT_OVERRIDE   # a porta do Dolt é do PROCESSO: um override de selftest no ambiente não pode ditar a resposta de um veredito real
LIB="$HERE/../dolt-pid-lib.sh"; LIB_OK=0
if [ -r "$LIB" ]; then . "$LIB" && LIB_OK=1; set +o pipefail; fi
IMPARAVEL="${GONOGO_IMPARAVEL:-$CITY/scripts/imparavel-check.py}"; PAINEIS="${GONOGO_PAINEIS:-$HERE/paineis.tsv}"; CELULARES="${GONOGO_CELULARES:-$HERE/celulares.tsv}"
BD_STORES="${GONOGO_BD_STORES:-hq=$CITY wa=${HOME:-}/gt/whatsapp_automation}"; VOLUME="${GONOGO_VOLUME:-/System/Volumes/Data}"
CF_CONFIG="${CLOUDFLARED_CONFIG:-${HOME:-}/.cloudflared/urblink-ops.yml}"
LABEL_SUPERVISOR="${GONOGO_LABEL_SUPERVISOR:-com.gascity.supervisor}"; LABEL_PILOT="${GONOGO_LABEL_PILOT:-com.gascity.pilot}"; LABEL_GATE="${GONOGO_LABEL_GATE:-com.gascity.quality-gate-dispatcher}"
LABEL_TUNEL="${GONOGO_LABEL_TUNEL:-br.urblink.cloudflared.urblink-ops}"; LABEL_SENDER="${GONOGO_LABEL_SENDER:-com.whatsapp.central-sender}"
MARCADOR="${GONOGO_ESPERA_MARCADOR:-}"; [ -n "$MARCADOR" ] || [ -z "${HOME:-}" ] || MARCADOR="$HOME/.mini64-espera"
# inteiro positivo de até 9 dígitos, senão o padrão: texto, vazio, zero ou negativo nunca valem (0 desligaria um limite)
num_or() { case "$1" in (''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac; [ "${#1}" -le 9 ] || { printf '%s' "$2"; return 0; }; [ "$((10#$1))" -ge 1 ] || { printf '%s' "$2"; return 0; }; printf '%s' "$((10#$1))"; }
TMO="$(num_or "${GONOGO_TIMEOUT:-}" 20)"; [ "$TMO" -le 20 ] || TMO=20
BD_SLOW_S="$(num_or "${GONOGO_BD_SLOW_S:-}" 10)"; DISCO_MIN_MB="$(num_or "${GONOGO_DISCO_MIN_MB:-}" 102400)"; SWAP_MAX_MB="$(num_or "${GONOGO_SWAP_MAX_MB:-}" 2048)"
HTTP_OK="${GONOGO_HTTP_OK:-200 401 403}"; case "$HTTP_OK" in (*[!0-9\ ]*) HTTP_OK="200 401 403" ;; esac
PRAZO="${GONOGO_PRAZO:-04:30}"; PRAZO_NOTA=""
case "$PRAZO" in ([01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; (*) PRAZO_NOTA=" (GONOGO_PRAZO inválido: '$PRAZO'; usei 04:30)"; PRAZO="04:30" ;; esac
usage() { cat <<'EOF'
uso: go-nogo.sh [--espera ligada|desligada] [--help]
  Uma linha por checagem ([OK] / [NO-GO] / [INCERTO]) e, na última linha, o VEREDITO:
    GO (exit 0): tudo OK · NO-GO (exit 1): ao menos uma falha CONFIRMADA · INCERTO (exit 2): nenhuma falha confirmada, mas alguma
    leitura não respondeu (comando ausente, estouro de prazo, saída ilegível); o INCERTO nunca conta como GO. exit 64 = uso errado.
  O script só lê: nada é carregado, parado, gravado nem enviado.
  --espera <estado>  como o marcador de espera (fatia .2) deve estar AGORA: ligada (padrão, antes dos envios do WhatsApp) ou desligada (depois do go).
  O que fazer em cada veredito e o horário-limite: docs/runbooks/mini64/03-go-nogo.md
EOF
}
usage_err() { printf 'go-nogo.sh: %s\n' "$1" >&2; usage >&2; exit 64; }
ESPERA="ligada"
while [ $# -gt 0 ]; do
  case "$1" in
    (--help|-h) usage; exit 0 ;;
    (--espera) [ $# -ge 2 ] || usage_err "--espera pede um valor (ligada ou desligada)"; ESPERA="$2"; shift 2 ;;
    (*) usage_err "opção desconhecida: $1" ;;
  esac
done
case "$ESPERA" in (ligada|desligada) ;; (*) usage_err "--espera: valor inválido '$ESPERA' (ligada ou desligada)" ;; esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/go-nogo.XXXXXX" 2>/dev/null)" || { echo "go-nogo.sh: não consegui criar o diretório de trabalho em ${TMPDIR:-/tmp}" >&2; echo "VEREDITO: INCERTO — nenhuma checagem rodou"; exit 2; }
cleanup() { rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null; return 0; }
trap cleanup EXIT; trap 'exit 130' INT TERM

# bounded <segundos> <comando ou função> [args]: stdout em $RB_OUT, stderr em $RB_ERR. rc do comando; 124 = estourou (TERM, 1 s de graça, KILL; filhos primeiro); 125 = não consegui lançar; 127 = comando ausente
RB_N=0; RB_OUT=""; RB_ERR=""
bounded() {
  local secs="$1" pid elapsed_ms=0 step_ms=20 limit_ms g
  shift
  command -v "$1" >/dev/null 2>&1 || return 127
  RB_N=$((RB_N + 1)); RB_OUT="$WORK/out.$RB_N"; RB_ERR="$WORK/err.$RB_N"
  : > "$RB_OUT" 2>/dev/null && : > "$RB_ERR" 2>/dev/null || return 125
  "$@" > "$RB_OUT" 2> "$RB_ERR" < /dev/null &
  pid=$!; limit_ms=$((secs * 1000))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed_ms" -ge "$limit_ms" ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      g=0; while [ "$g" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; g=$((g + 1)); done
      if kill -0 "$pid" 2>/dev/null; then pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
      wait "$pid" 2>/dev/null; return 124
    fi
    sleep "$(printf '0.%03d' "$step_ms")"; elapsed_ms=$((elapsed_ms + step_ms))
    step_ms=$((step_ms * 2)); [ "$step_ms" -le 200 ] || step_ms=200
  done
  wait "$pid"
}
# o começo de um arquivo de saída, numa linha só, curto
snip() { local t; { t="$(<"$1")"; } 2>/dev/null; t="${t//$'\n'/ }"; t="${t//$'\r'/ }"; t="${t//$'\t'/ }"; printf '%s' "${t:0:110}"; }
N_OK=0; N_NOGO=0; N_INC=0
report() {  # report <ok|nogo|inc> <nome> <detalhe>
  local tag d="$3"
  case "$1" in (ok) tag="OK"; N_OK=$((N_OK + 1)) ;; (nogo) tag="NO-GO"; N_NOGO=$((N_NOGO + 1)) ;; (*) tag="INCERTO"; N_INC=$((N_INC + 1)) ;; esac
  d="${d//$'\n'/ }"; d="${d//$'\r'/ }"; d="${d//$'\t'/ }"
  printf '%-9s %-24s %s\n' "[$tag]" "$2" "${d:0:230}"
}
# rc 124/125/127 de bounded viram a frase de INCERTO; rc 0 desta função = já reportou (o chamador faz return)
bounded_inc() {  # bounded_inc <nome> <rc> <comando> <o que era>
  case "$2" in
    (127) report inc "$1" "comando $3 ausente no PATH"; return 0 ;;
    (124) report inc "$1" "$4 estourou $TMO s"; return 0 ;;
    (125) report inc "$1" "não consegui lançar $3 (diretório de trabalho sem escrita)"; return 0 ;;
  esac
  return 1
}

chk_dolt() {
  local rc port
  if [ "$LIB_OK" != 1 ]; then report inc dolt-porta "dolt-pid-lib.sh ausente ou ilegível em $LIB: sem porta viva"; return; fi
  # vazio → INCERTO (sem processo ou porta; a lib não separa "Dolt fora" de "não consegui ver"); falhou/estourou/ilegível → INCERTO
  bounded "$TMO" dolt_server_live_port; rc=$?
  if [ "$rc" -eq 124 ]; then report inc dolt-porta "identificar o processo do Dolt estourou $TMO s: sem porta viva"; return; fi
  port="$(<"$RB_OUT")"
  case "$port" in
    (''|*[!0-9]*) report inc dolt-porta "não identifiquei o processo do Dolt nem a porta dele (rc $rc): sem porta viva" ;;
    (*) if [ "$rc" -eq 0 ]; then report ok dolt-porta "porta viva $port (lida do processo dolt, nunca de arquivo)"; else report inc dolt-porta "a lib respondeu '$port' com rc $rc: sem porta viva"; fi ;;
  esac
}
chk_bd() {  # chk_bd <nome> <caminho do store>
  local nome="$1" root="$2" rc t0 dt first
  t0=$SECONDS
  # vazio → INCERTO (rc 0 sem lista: o Dolt não respondeu com dado); falhou → INCERTO (Dolt fora, porta velha ou trava: sem prova de qual); estourou/lento → INCERTO
  bounded "$TMO" bd -C "$root" list -n 1 --json; rc=$?; dt=$((SECONDS - t0))
  bounded_inc "bd-$nome" "$rc" bd "bd list" && return
  if [ "$rc" -ne 0 ]; then report inc "bd-$nome" "bd list falhou (rc $rc): $(snip "$RB_ERR")"; return; fi
  first="$(<"$RB_OUT")"; first="${first#"${first%%[![:space:]]*}"}"; first="${first:0:1}"
  if [ "$first" != "[" ]; then report inc "bd-$nome" "bd list respondeu rc 0 com resposta ilegível (não é uma lista JSON): $(snip "$RB_OUT")"; return; fi
  if [ "$dt" -ge "$BD_SLOW_S" ]; then report inc "bd-$nome" "bd list lento ($dt s, limite $BD_SLOW_S s) em $root"; return; fi
  report ok "bd-$nome" "bd list respondeu em $dt s ($root)"
}
chk_bds() {
  local pair nome root achou=0
  for pair in $BD_STORES; do
    nome="${pair%%=*}"; root="${pair#*=}"
    case "$nome" in (''|*[!A-Za-z0-9._-]*) report inc bd-lista "GONOGO_BD_STORES: nome inválido em '$pair'"; continue ;; esac
    if [ "$root" = "$pair" ] || [ -z "$root" ]; then report inc bd-lista "GONOGO_BD_STORES: falta o caminho em '$pair' (esperado nome=caminho)"; continue; fi
    achou=1; chk_bd "$nome" "$root"
  done
  [ "$achou" = 1 ] || report inc bd-lista "GONOGO_BD_STORES sem nenhum banco para conferir"
}

# launchd_read <label>: LD_STATE = rodando | carregado (sem PID) | ausente; LD_PID; rc 0 = deu para ler, rc 1 = não deu (LD_WHY diz por quê)
LD_STATE=""; LD_PID=""; LD_WHY=""
launchd_read() {
  local label="$1" rc out err pid=""
  LD_STATE=""; LD_PID=""; LD_WHY=""
  # vazio → o dicionário do job tem de existir (rc 0 sem ele = não sei); falhou → só "Could not find service" é "não está carregado", outro erro é "não sei"
  bounded "$TMO" launchctl list "$label"; rc=$?
  case "$rc" in
    (127) LD_WHY="comando launchctl ausente no PATH"; return 1 ;;
    (124) LD_WHY="launchctl list $label estourou $TMO s"; return 1 ;;
    (125) LD_WHY="não consegui lançar launchctl (diretório de trabalho sem escrita)"; return 1 ;;
  esac
  out="$(<"$RB_OUT")"; err="$(<"$RB_ERR")"
  if [ "$rc" -ne 0 ]; then
    case "$out$err" in (*"Could not find service"*) LD_STATE="ausente"; return 0 ;; esac
    LD_WHY="launchctl list $label rc $rc: $(snip "$RB_ERR")"; return 1
  fi
  case "$out" in (*'"Label"'*) ;; (*) LD_WHY="launchctl list $label rc 0 mas sem dicionário do job: $(snip "$RB_OUT")"; return 1 ;; esac
  case "$out" in (*'"PID" = '*) pid="${out#*'"PID" = '}"; pid="${pid%%;*}" ;; esac
  case "$pid" in (''|*[!0-9]*) LD_STATE="carregado" ;; (*) LD_STATE="rodando"; LD_PID="$pid" ;; esac
  return 0
}
chk_job() {  # chk_job <nome> <label> <pid|carregado: o que conta como vivo>
  launchd_read "$2" || { report inc "$1" "$LD_WHY"; return; }
  case "$LD_STATE" in
    (ausente) report nogo "$1" "$2 não está carregado no launchd" ;;
    (rodando) report ok "$1" "$2 rodando (pid $LD_PID)" ;;
    (*) if [ "$3" = pid ]; then report nogo "$1" "$2 carregado sem PID (não está rodando)"; else report ok "$1" "$2 carregado (job de intervalo: sem PID entre as execuções)"; fi ;;
  esac
}
chk_gc() {
  local rc
  # vazio → ok se rc 0 (a lista pode estar vazia); falhou → INCERTO (supervisor fora, trava ou erro: o job do supervisor tem linha própria)
  bounded "$TMO" gc session list; rc=$?
  bounded_inc gc "$rc" gc "gc session list" && return
  if [ "$rc" -eq 0 ]; then report ok gc "gc session list respondeu"; else report inc gc "gc session list falhou (rc $rc): $(snip "$RB_ERR")"; fi
}
chk_imparavel() {
  local rc vline="" want verdict _l
  if [ ! -r "$IMPARAVEL" ]; then report inc imparavel "$IMPARAVEL ausente ou ilegível"; return; fi
  # vazio → INCERTO (sem linha VEREDITO: um crash também sai rc 1 e NÃO é "não imparável"); falhou/estourou → INCERTO; rc que não bate com a linha → INCERTO
  bounded "$TMO" python3 "$IMPARAVEL"; rc=$?
  bounded_inc imparavel "$rc" python3 "imparavel-check.py" && return
  while IFS= read -r _l; do case "$_l" in (VEREDITO:*) vline="$_l"; break ;; esac; done < "$RB_OUT"
  if [ -z "$vline" ]; then report inc imparavel "rc $rc e sem linha VEREDITO na saída (quebrou?): $(snip "$RB_ERR")"; return; fi
  case "$vline" in
    (*"NÃO IMPARÁVEL"*) want=1; verdict=nogo ;;
    (*INCERTO*) want=2; verdict=inc ;;
    (*"IMPARÁVEL agora"*) want=0; verdict=ok ;;
    (*) report inc imparavel "linha VEREDITO que não reconheço: $vline"; return ;;
  esac
  if [ "$rc" -ne "$want" ]; then report inc imparavel "o rc ($rc) não bate com a linha ($vline): leia a saída dele à mão"; return; fi
  report "$verdict" imparavel "$vline"
}
chk_painel() {  # chk_painel <nome> <porta> <caminho>
  local url="http://127.0.0.1:$2$3" rc code
  # vazio → INCERTO (curl sem código HTTP); falhou → rc 7 = NO-GO (em loopback "recusada" é "nada escuta"), outro rc = INCERTO; ilegível → INCERTO
  bounded "$TMO" curl -sS -g -o /dev/null -w '%{http_code}' --max-time "$TMO" "$url"; rc=$?
  bounded_inc "painel-$1" "$rc" curl "curl em $url" && return
  code="$(<"$RB_OUT")"
  case "$rc" in
    (0) ;;
    (7) report nogo "painel-$1" "conexão recusada em $url: nada escuta na porta $2"; return ;;
    (*) report inc "painel-$1" "curl rc $rc sem resposta em $url: $(snip "$RB_ERR")"; return ;;
  esac
  case "$code" in ([0-9][0-9][0-9]) ;; (*) report inc "painel-$1" "resposta ilegível de $url (código '$code')"; return ;; esac
  case " $HTTP_OK " in (*" $code "*) report ok "painel-$1" "HTTP $code em $url" ;; (*) report nogo "painel-$1" "HTTP $code em $url (aceito: $HTTP_OK)" ;; esac
}
chk_paineis() {
  local nome porta caminho rest n=0 lineno=0 ruim
  if [ ! -r "$PAINEIS" ]; then report inc paineis "lista de painéis ausente ou ilegível: $PAINEIS"; return; fi
  # vazio → INCERTO (nenhum painel listado); linha ilegível → INCERTO com o número da linha (as boas continuam); arquivo que não abre → INCERTO
  while IFS="$TAB" read -r nome porta caminho rest; do
    lineno=$((lineno + 1)); caminho="${caminho%$'\r'}"
    case "$nome" in (''|'#'*) continue ;; esac
    ruim=0
    case "$nome" in (*[!A-Za-z0-9._-]*) ruim=1 ;; esac
    case "$porta" in (''|*[!0-9]*) ruim=1 ;; (*) if [ "${#porta}" -gt 5 ] || [ "$porta" -lt 1 ] || [ "$porta" -gt 65535 ]; then ruim=1; fi ;; esac
    case "$caminho" in (/*) ;; (*) ruim=1 ;; esac
    case "$caminho" in (*[[:space:]]*) ruim=1 ;; esac
    if [ "$ruim" = 1 ]; then report inc paineis "linha $lineno ilegível em $PAINEIS (esperado: nome<TAB>porta<TAB>caminho): '$nome'"; continue; fi
    n=$((n + 1)); chk_painel "$nome" "$porta" "$caminho"
  done < "$PAINEIS"
  [ "$n" -gt 0 ] || report inc paineis "nenhum painel listado em $PAINEIS"
}
chk_adb() {
  local serial apelido rest n=0 ok_n=0 achados=0 rc estado problemas="" lineno=0 listados="" ruim="" linha hdr=0 devs="" total=0 resto
  if [ ! -r "$CELULARES" ]; then report inc adb "lista de celulares ausente ou ilegível: $CELULARES"; return; fi
  # vazio → INCERTO (lista sem nenhum serial: não sei o que esperar); linha ilegível → INCERTO; arquivo que não abre → INCERTO
  while IFS="$TAB" read -r serial apelido rest; do
    lineno=$((lineno + 1)); serial="${serial%$'\r'}"; apelido="${apelido%$'\r'}"
    case "$serial" in (''|'#'*) continue ;; esac
    case "$serial" in (*[!A-Za-z0-9._:-]*) ruim="$ruim linha $lineno;"; continue ;; esac
    [ -n "$apelido" ] || apelido="$serial"
    n=$((n + 1)); listados="$listados$serial$TAB$apelido
"
  done < "$CELULARES"
  if [ -n "$ruim" ]; then report inc adb "serial ilegível em $CELULARES:$ruim"; return; fi
  if [ "$n" -eq 0 ]; then report inc adb "lista vazia: nenhum serial em $CELULARES (preencha com os seriais de 'adb devices -l', sem número de telefone)"; return; fi
  # vazio → INCERTO (sem o cabeçalho conhecido); falhou/estourou → INCERTO; serial fora da lista do adb → NO-GO só com o cabeçalho presente (o adb respondeu e o celular não está)
  bounded "$TMO" adb devices; rc=$?
  bounded_inc adb "$rc" adb "adb devices" && return
  if [ "$rc" -ne 0 ]; then report inc adb "adb devices falhou (rc $rc): $(snip "$RB_ERR")"; return; fi
  while IFS= read -r linha; do
    linha="${linha%$'\r'}"
    case "$linha" in ('List of devices attached'*) hdr=1; continue ;; esac
    [ "$hdr" = 1 ] || continue
    set -f; set -- $linha; set +f
    [ $# -ge 2 ] && [ "$1" != "*" ] || continue
    devs="$devs|$1=$2"; total=$((total + 1))
  done < "$RB_OUT"
  if [ "$hdr" != 1 ]; then report inc adb "saída ilegível: sem o cabeçalho 'List of devices attached': $(snip "$RB_OUT")"; return; fi
  while IFS="$TAB" read -r serial apelido; do
    [ -n "$serial" ] || continue
    resto="${devs#*|$serial=}"
    if [ "$resto" = "$devs" ]; then problemas="$problemas $apelido ($serial): não aparece;"; continue; fi
    estado="${resto%%|*}"; achados=$((achados + 1))
    if [ "$estado" = device ]; then ok_n=$((ok_n + 1)); else problemas="$problemas $apelido ($serial): $estado;"; fi
  done <<EOF
$listados
EOF
  if [ -n "$problemas" ]; then report nogo adb "$ok_n/$n celulares em estado device;$problemas"; else report ok adb "$ok_n/$n celulares em estado device (+$((total - achados)) fora da lista)"; fi
}
chk_cf_conectores() {
  local id="" rc n=0 hdr=0 _l _t _h UUID_GLOB
  if [ ! -r "$CF_CONFIG" ]; then report inc cloudflared-conectores "config do túnel ausente ou ilegível: $CF_CONFIG"; return; fi
  # vazio → INCERTO (config sem a chave tunnel:); falhou/ilegível → INCERTO
  while IFS= read -r _l; do case "$_l" in (tunnel:*) id="${_l#tunnel:}"; id="${id//[[:space:]]/}"; break ;; esac; done < "$CF_CONFIG"
  case "$id" in
    ('') report inc cloudflared-conectores "config $CF_CONFIG sem a chave tunnel:"; return ;;
    (*[!0-9a-fA-F-]*) report inc cloudflared-conectores "tunnel: '$id' em $CF_CONFIG não parece um UUID"; return ;;
  esac
  # vazio → INCERTO (sem linha ID: o formato não é o que conheço); 0 linhas de conector → INCERTO (túnel fora ou formato mudou: não sei qual); falhou/estourou → INCERTO
  bounded "$TMO" cloudflared tunnel info "$id"; rc=$?
  bounded_inc cloudflared-conectores "$rc" cloudflared "cloudflared tunnel info" && return
  if [ "$rc" -ne 0 ]; then report inc cloudflared-conectores "cloudflared tunnel info falhou (rc $rc): $(snip "$RB_ERR")"; return; fi
  _h='[0-9a-fA-F]'; UUID_GLOB="$_h$_h$_h$_h$_h$_h$_h$_h-$_h$_h$_h$_h-$_h$_h$_h$_h-$_h$_h$_h$_h-$_h$_h$_h$_h$_h$_h$_h$_h$_h$_h$_h$_h"
  while IFS= read -r _l; do
    case "$_l" in
      ('ID:'*) hdr=1 ;;
      ($UUID_GLOB*) _t="${_l:36:1}"; if [ -z "$_t" ] || [ "$_t" = " " ]; then n=$((n + 1)); fi ;;
    esac
  done < "$RB_OUT"
  if [ "$hdr" != 1 ]; then report inc cloudflared-conectores "formato não reconhecido (sem a linha ID:): $(snip "$RB_OUT")"; return; fi
  case "$n" in
    (1) report ok cloudflared-conectores "1 conector ativo no túnel $id" ;;
    (0) report inc cloudflared-conectores "0 conectores lidos no túnel $id (túnel fora ou formato mudou: não sei qual)" ;;
    (*) report nogo cloudflared-conectores "$n conectores ativos no túnel $id (esperado 1: o servidor antigo ainda está vivo?)" ;;
  esac
}
chk_disco() {
  local rc livre="" mp="" _h _fs _blocks _usado _cap
  # vazio → INCERTO; falhou → INCERTO; df de outro ponto de montagem (a raiz selada mostra o volume errado) → INCERTO, nunca "tem bastante"
  bounded "$TMO" df -Pm "$VOLUME"; rc=$?
  bounded_inc disco "$rc" df "df" && return
  if [ "$rc" -ne 0 ]; then report inc disco "df falhou (rc $rc): $(snip "$RB_ERR")"; return; fi
  { read -r _h; read -r _fs _blocks _usado livre _cap mp; } < "$RB_OUT"
  case "$livre" in (''|*[!0-9]*) report inc disco "leitura ilegível do df de $VOLUME: $(snip "$RB_OUT")"; return ;; esac
  if [ "$mp" != "$VOLUME" ]; then report inc disco "leitura ilegível: o df respondeu o ponto de montagem '$mp', não $VOLUME"; return; fi
  if [ "${#livre}" -gt 9 ]; then report inc disco "leitura ilegível: número grande demais ('$livre')"; return; fi
  if [ "$((10#$livre))" -lt "$DISCO_MIN_MB" ]; then report nogo disco "$livre MB livres em $VOLUME, abaixo do piso de $DISCO_MIN_MB MB"
  else report ok disco "$((10#$livre / 1024)) GB livres em $VOLUME (piso $((DISCO_MIN_MB / 1024)) GB)"; fi
}
sysctl_c() { LC_ALL=C sysctl "$@"; }
chk_swap() {
  local rc usado="" linha tok n u ip fp
  # vazio → INCERTO; falhou → INCERTO; unidade que não é M nem G, ou número ilegível → INCERTO (não sei ≠ 0 MB). LC_ALL=C: no pt_BR o sysctl imprime vírgula decimal; a vírgula também é aceita
  bounded "$TMO" sysctl_c -n vm.swapusage; rc=$?
  bounded_inc swap "$rc" sysctl "sysctl vm.swapusage" && return
  if [ "$rc" -ne 0 ]; then report inc swap "sysctl vm.swapusage falhou (rc $rc): $(snip "$RB_ERR")"; return; fi
  linha="$(<"$RB_OUT")"; set -f; set -- $linha; set +f
  while [ $# -gt 0 ]; do
    if [ "$1" = used ] && [ $# -ge 3 ]; then
      tok="$3"; u="${tok: -1}"; n="${tok%?}"; ip="${n%%[.,]*}"; fp=""
      case "$n" in (*[.,]*) fp="${n#*[.,]}" ;; esac
      case "$u:$n:$ip:$fp" in (M:*|G:*) ;; (*) break ;; esac
      case "$n$ip$fp" in (''|*[!0-9.,]*) break ;; esac
      case "$ip" in (''|*[!0-9]*) break ;; esac
      case "$fp" in (*[!0-9]*) break ;; esac
      [ "${#ip}" -le 9 ] || break
      fp="${fp}00"; fp="${fp:0:2}"
      if [ "$u" = G ]; then usado=$((10#$ip * 1024 + 10#$fp * 1024 / 100)); else usado=$((10#$ip)); fi
      break
    fi
    shift
  done
  case "$usado" in (''|*[!0-9]*) report inc swap "leitura ilegível de vm.swapusage: $(snip "$RB_OUT")"; return ;; esac
  if [ "$((10#$usado))" -gt "$SWAP_MAX_MB" ]; then report nogo swap "$usado MB de swap em uso, acima do teto de $SWAP_MAX_MB MB"
  else report ok swap "$usado MB de swap em uso (teto $SWAP_MAX_MB MB)"; fi
}
chk_espera() {
  local dir presente=0
  if [ -z "$MARCADOR" ]; then report inc espera "caminho do marcador vazio (HOME vazio e GONOGO_ESPERA_MARCADOR sem valor)"; return; fi
  case "$MARCADOR" in */*) dir="${MARCADOR%/*}"; [ -n "$dir" ] || dir="/" ;; *) dir="." ;; esac
  # vazio → ausente só se a pasta dele dá para olhar; pasta que não existe ou não abre → INCERTO ("não consigo olhar" ≠ "o marcador não existe")
  if [ ! -d "$dir" ] || [ ! -x "$dir" ]; then report inc espera "não consigo olhar: a pasta $dir não existe ou não abre"; return; fi
  # marcador que existe mas não é um arquivo legível (pasta, link, sem permissão) → INCERTO: a fatia .2 também lê isso como "nao-sei"
  if [ -f "$MARCADOR" ] && [ -r "$MARCADOR" ]; then presente=1
  elif [ -e "$MARCADOR" ] || [ -L "$MARCADOR" ]; then report inc espera "o marcador $MARCADOR existe mas não é um arquivo legível (a fatia .2 lê isso como nao-sei)"; return; fi
  if [ "$ESPERA" = ligada ] && [ "$presente" = 1 ]; then report ok espera "marcador presente em $MARCADOR (esperado: ligada)"
  elif [ "$ESPERA" = ligada ]; then report nogo espera "marcador ausente em $MARCADOR (esperado: ligada): a espera NÃO está ligada, a cidade pode carregar e enviar"
  elif [ "$presente" = 0 ]; then report ok espera "marcador ausente em $MARCADOR (esperado: desligada)"
  else report nogo espera "marcador presente em $MARCADOR (esperado: desligada): a espera ainda está ligada"; fi
}
chk_envio() {
  launchd_read "$LABEL_SENDER" || { report inc envio "$LD_WHY"; return; }
  if [ "$ESPERA" = ligada ]; then
    case "$LD_STATE" in
      (ausente) report ok envio "$LABEL_SENDER não carregado (esperado com a espera ligada: nada envia)" ;;
      (*) report nogo envio "$LABEL_SENDER carregado com a espera ligada: pode estar enviando (o rollback real só existe até o 1º envio)" ;;
    esac
  else
    case "$LD_STATE" in
      (rodando) report ok envio "$LABEL_SENDER rodando (pid $LD_PID)" ;;
      (carregado) report nogo envio "$LABEL_SENDER carregado sem PID (esperado rodando com a espera desligada)" ;;
      (*) report nogo envio "$LABEL_SENDER não está carregado com a espera desligada" ;;
    esac
  fi
}
# horário-limite: informação, não checagem
prazo_linha() {
  local hhmm hh mm agora limite delta
  # vazio/falhou/ilegível → "hora ilegível" (nenhum minuto inventado; não muda o veredito)
  hhmm="$(date +%H%M 2>/dev/null)" || hhmm=""
  case "$hhmm" in
    ([01][0-9][0-5][0-9]|2[0-3][0-5][0-9]) ;;
    (*) printf 'PRAZO %s: hora ilegível (date respondeu "%s"); confira o relógio à mão%s\n' "$PRAZO" "$hhmm" "$PRAZO_NOTA"; return 0 ;;
  esac
  hh="${hhmm%??}"; mm="${hhmm#??}"
  agora=$((10#$hh * 60 + 10#$mm)); limite=$((10#${PRAZO%%:*} * 60 + 10#${PRAZO##*:})); delta=$((limite - agora))
  if [ "$delta" -ge 0 ]; then printf 'PRAZO %s: faltam %s min%s\n' "$PRAZO" "$delta" "$PRAZO_NOTA"
  elif [ "$agora" -lt 720 ]; then printf 'PRAZO %s: PASSOU há %s min — sem GO até agora vale NO-GO (rollback)%s\n' "$PRAZO" "$((0 - delta))" "$PRAZO_NOTA"
  else printf 'PRAZO %s: faltam %s min (o próximo horário-limite)%s\n' "$PRAZO" "$((delta + 1440))" "$PRAZO_NOTA"; fi
}

printf 'GO/NO-GO mini 64 — %s — host %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "$(hostname -s 2>/dev/null || echo '?')"
printf 'timeout por checagem: %s s · espera esperada: %s\n' "$TMO" "$ESPERA"
prazo_linha
chk_dolt; chk_bds
chk_job supervisor "$LABEL_SUPERVISOR" pid; chk_job pilot "$LABEL_PILOT" carregado; chk_job gate "$LABEL_GATE" carregado
chk_gc; chk_imparavel; chk_paineis; chk_adb
chk_job cloudflared-job "$LABEL_TUNEL" pid; chk_cf_conectores
chk_disco; chk_swap; chk_espera; chk_envio
if [ "$N_NOGO" -gt 0 ]; then VEREDITO="NO-GO"; RC=1
elif [ "$N_INC" -gt 0 ]; then VEREDITO="INCERTO"; RC=2
elif [ "$N_OK" -gt 0 ]; then VEREDITO="GO"; RC=0
else VEREDITO="INCERTO"; RC=2; fi
echo "Leia: docs/runbooks/mini64/03-go-nogo.md (o que fazer em GO, NO-GO e INCERTO; horário-limite $PRAZO)"
printf 'VEREDITO: %s — %s falha(s), %s incerto(s), %s ok\n' "$VEREDITO" "$N_NOGO" "$N_INC" "$N_OK"
exit "$RC"
