#!/bin/bash
# disk-recovery-d35-load-shed.sh — degrau D3.5 da escada de recuperação de disco do mini (ga-1p1i5jr.8, missão ga-1p1i5jr): CORTE DE CARGA, entre o D3 e o D4 e também DEPOIS do teto do D4.
#
# ## Contents
#   Para que serve · Uso · Contrato · A allowlist e a deny-list · O registro · Retomar · Três estados · Variáveis · Teste
#
# PARA QUE SERVE. Athos 09/11: "se chegar a 3a necessidade e o reboot nao vem, o q acontece? me parece que a gente fica travado". O D4 tem teto (2 reinícios/24 h, 6 h de cooldown) e depois dele a escada só avisava "precisa de um humano" com o
#   disco seguindo a cair (o swap sai do MESMO disco; 15/10 Dolt ENOSPC); o D3 reinicia os daemons de RAM e eles devolvem a mesma RAM em minutos. Aqui se PARA (launchctl disable + bootout: não restart, e o disable sobrevive ao reboot)
#   serviço NÃO essencial da allowlist, em ordem, até o livre voltar a >= 3 GB; e se RELIGA sozinho quando o disco volta a >= 6 GB por 30 min (espelho do --resume do D2). Quem chama é o maestro (disk-recovery-ladder.sh).
# USO   --run (real) · --dry-run (diz o que pararia; lê o launchd, não grava nada) · --resume (religa o que o --run parou; seguro de repetir a cada rodada do maestro)
# CONTRATO  stdout: UMA linha ("D3.5 <modo>: ..."), sempre. Saída 0 agiu (parou N / religou 1) · 10 nada a fazer (disco ok, relógio de 30 min correndo, outra instância: NÃO diz "ainda corto") ·
#   11 (--run e --dry-run) LISTA ESGOTADA: nada mais a parar e o disco segue < 3 GB (o maestro só então deixa o "precisa de um humano" sair) · 12 (--run) ESPERANDO o efeito do último corte, ainda há o que cortar (com o 0, o único
#   código que segura o "precisa de um humano") · 20 falhou (disable/bootout/religar sem prova, registro que não grava) ·
#   30 não consegui ler o estado e por isso NÃO agi (df, allowlist, registro, launchctl) · 2 uso. Quem avisa o Athos (notify/mail) é o maestro: este degrau só escreve o próprio log.
# A ALLOWLIST E A DENY-LIST. Só se mexe em label de scripts/disk-recovery-d35-allowlist.tsv (versionada; ver o cabeçalho dela). A deny-list vive AQUI e VENCE a allowlist, em duas travas independentes (porta e fragmento do label):
#   sender, captura de inbound, voicebot/discador, túneis, Dolt, supervisor, HQ, classification, demand, map-viewer, frota, admin/daemon. Linha negada ou malformada é descartada e dita na linha de saída (quando o degrau chega a usar a lista).
#   Cada label só é parado se (a) o plist existe (sem ele não há como religar), (b) está carregado e (c) NÃO está desabilitado: o que o Athos já deixou desligado é decisão dele, nunca é tocado nem religado.
# O REGISTRO  $D35_STATE (padrão $CITY/.gc/disk-recovery-d35.state), TSV só de acréscimo: epoch EVENTO label pid livre detalhe (campo vazio = `-`). STOPPING é gravado ANTES de agir (sem registro não se para) → STOPPED (provado: o label saiu
#   do launchd) | STOP_FAILED (falhou e foi desfeito; fica de fora por D35_FAIL_COOL_S) · RESUMED | RESUME_FAILED | ABANDONED (já carregado e habilitado por outro; carregado mas ainda desabilitado = corte pela metade: só o enable). Pendente = último evento STOPPING, STOPPED ou RESUME_FAILED.
#   Ordem do corte = a do arquivo; a retomada é a inversa (o último parado volta primeiro), UM por chamada (a RAM volta aos poucos). Linha de registro cortada/ruim é ruído e é ignorada (um evento pela metade não apaga os anteriores).
# RETOMAR  Só o que o registro diz que EU parei. Com livre >= 6144 MB seguidos por 1800 s (conto só leituras minhas: lacuna > 600 s ou queda abaixo de 6144 zera o relógio, em $D35_HIGH). enable ANTES do bootstrap (label desabilitado não sobe);
#   a PROVA é o pid NOVO (diferente do que o parei) — job que não tinha pid ao parar (agendado): carregado. Sem prova = 20 e continua pendente (repete na chamada seguinte).
# TRÊS ESTADOS  tem / não-tem / não-consegui-saber. df, allowlist, registro, print-disabled e print ilegíveis NUNCA viram "disco bom", "lista esgotada" nem "nada a retomar": 30 e não age (label cujo `print` falha é pulado e conta como não lido).
#   O rc de um launchctl não prova nada (estourou o prazo PODE ter aplicado): o disable, o bootout e o religar são provados RELENDO. Falha no meio desfaz (enable) ou diz INCONSISTENTE e o registro o deixa pendente.
# VARIÁVEIS (todas opcionais; TESTE marcadas) D35_CITY D35_ALLOWLIST D35_STATE D35_HIGH D35_LOG D35_LOCK D35_PLIST_DIR D35_VOLUME D35_LAUNCHCTL_BIN D35_DF_BIN D35_DATE_BIN D35_PS_BIN D35_UID · DR_OFF_FILE · numéricas D35_STOP_BELOW_MB(3072) D35_RESUME_ABOVE_MB(6144)
#   D35_RESUME_HOLD_S(1800) D35_MAX_PER_RUN(3) D35_SPACING_S(600) D35_SETTLE_S(20) D35_BUDGET_S(300) D35_LC_TIMEOUT_S(30) D35_STOP_WAIT_S(10) D35_WATCH_S(20) D35_GAP_S(600) D35_FAIL_COOL_S(3600) · TESTE: D35_FREE_MB_FILE D35_NOW.
# TESTE  bash scripts/disk-recovery-d35-load-shed.selftest.sh   (hermético: launchctl, df e relógio simulados; nada real é parado)
#
# bash 3.2 (o /bin/bash do macOS): sem declare -A, mapfile, ${v,,}; `case` dentro de $( ) só com padrão entre parênteses.
set -uo pipefail
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

D=$(cd "$(dirname "$0")" && pwd)
CITY="${D35_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
ALLOW="${D35_ALLOWLIST:-$D/disk-recovery-d35-allowlist.tsv}"
STATE="${D35_STATE:-$GCDIR/disk-recovery-d35.state}"
HIGH="${D35_HIGH:-$GCDIR/disk-recovery-d35.high}"
LOG="${D35_LOG:-$GCDIR/logs/disk-recovery-d35.log}"
LOCKD="${D35_LOCK:-$GCDIR/disk-recovery-d35.lock.d}"
OFF="${DR_OFF_FILE:-$GCDIR/disk-recovery.off}"
PLISTS="${D35_PLIST_DIR:-$HOME/Library/LaunchAgents}"
VOLUME="${D35_VOLUME:-/System/Volumes/Data}"
LC_BIN="${D35_LAUNCHCTL_BIN:-launchctl}"
DF_BIN="${D35_DF_BIN:-df}"
DATE_BIN="${D35_DATE_BIN:-date}"
PS_BIN="${D35_PS_BIN:-ps}"
UIDN="${D35_UID:-$(id -u)}"
TAB=$(printf '\t')
NL='
'
num() {  # $1=nome $2=padrão → só dígitos, até 9; lixo cai no padrão
  local v; eval "v=\${$1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "${#v}" -le 9 ] || v=$2
  printf '%s' "$v"
}
STOP_BELOW_MB=$(num D35_STOP_BELOW_MB 3072); RESUME_ABOVE_MB=$(num D35_RESUME_ABOVE_MB 6144); RESUME_HOLD_S=$(num D35_RESUME_HOLD_S 1800)
MAX_PER_RUN=$(num D35_MAX_PER_RUN 3); SPACING_S=$(num D35_SPACING_S 600); SETTLE_S=$(num D35_SETTLE_S 20); BUDGET_S=$(num D35_BUDGET_S 300)
LC_TIMEOUT_S=$(num D35_LC_TIMEOUT_S 30); STOP_WAIT_S=$(num D35_STOP_WAIT_S 10); WATCH_S=$(num D35_WATCH_S 20); GAP_S=$(num D35_GAP_S 600); FAIL_COOL_S=$(num D35_FAIL_COOL_S 3600)

# NUNCA, mesmo na allowlist (a lista do bead + a do botão Ligar/Desligar do admin, wa-g2fryg.9.1). Duas travas independentes: a porta e o fragmento do label (sem maiúsculas)
DENY_PORTS=" 8086 8095 8099 8203 8090 8097 5599 5600 8088 "
DENY_FRAGS="sender inbound discador dialer voicebot phoneproxy tunnel classification demand-dashboard map-viewer frota admin-dashboard daemon-dashboard dolt supervisor gascity gastown"
DENY_WHY=""
denied() {  # $1=label $2=porta → rc 0 se NEGADO (DENY_WHY diz qual trava)
  local f lbl
  case "$DENY_PORTS" in *" $2 "*) DENY_WHY="porta $2"; return 0 ;; esac
  lbl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for f in $DENY_FRAGS; do case "$lbl" in *"$f"*) DENY_WHY="«$f»"; return 0 ;; esac; done
  return 1
}

MODE=""; DRY=0; DONE=0; LOCK_HELD=0; RB=""; NOW=0; FREE=0; WHY=""; ST=""; PID=""; STOPERR=""; RESUME_PID=""
ROWS=""; SKIP_N=0; DISABLED=" "; PENDING=""; LAST_CUT=0; FAILED=" "; HELD=0

log() {  # só no modo real: o --dry-run não escreve nada em disco
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  { printf '%s D3.5 %s: %s\n' "$(date '+%F %T')" "${MODE:-?}" "$*" >> "$LOG"; } 2>/dev/null || true
}
cleanup() {
  [ -n "$RB" ] && rm -f "$RB" 2>/dev/null
  if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCKD/pid" 2>/dev/null; rmdir "$LOCKD" 2>/dev/null; fi
  return 0
}
finish() {  # $1=rc $2=texto → UMA linha no stdout e sai
  DONE=1; log "FIM rc=$1: $2"; printf 'D3.5 %s: %s\n' "${MODE:-?}" "$2"; cleanup; exit "$1"
}
on_exit() {
  local rc=$?
  [ "$DONE" = 1 ] && return 0
  DONE=1; log "ERRO INTERNO rc=$rc (o script saiu sem concluir)"
  printf 'D3.5 %s: erro interno (rc=%s); não sei se agiu; ver %s\n' "${MODE:-?}" "$rc" "$LOG"
  cleanup; exit 20
}
usage() { DONE=1; echo "uso: $0 --run | --dry-run | --resume" >&2; exit 2; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
now() { case "${D35_NOW:-}" in ''|*[!0-9]*) "$DATE_BIN" +%s ;; *) printf '%s' "$D35_NOW" ;; esac; }

lc() {  # argumentos do launchctl → saída em $RB, rc dele; 124 = estourou D35_LC_TIMEOUT_S (PODE ter aplicado: quem chama RELÊ, não confia no rc); 125 = sem arquivo temporário
  local pid i=0 max=$((LC_TIMEOUT_S * 20))
  [ -n "$RB" ] || RB=$(mktemp "${TMPDIR:-/tmp}/d35-lc.XXXXXX") || { RB=""; return 125; }
  : > "$RB"
  "$LC_BIN" "$@" >"$RB" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 0.05; i=$((i + 1))
  done
  wait "$pid"
}
lc_state() {  # $1=label → ST = loaded | unloaded | unknown; PID = pid lido (vazio se não há). print: rc 0 = carregado, rc 113 = não carregado; qualquer outro rc ou estouro = unknown (não é "não carregado")
  # vazio (sem linha "pid = N": job agendado) → PID vazio; falhou/ilegível (rc ≠ 0/113, estouro) → unknown
  PID=""; lc print "gui/$UIDN/$1"; local rc=$?
  case "$rc" in
    0) ST=loaded; PID=$(awk '$1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3; exit }' "$RB") ;;
    113) ST=unloaded ;;
    *) ST=unknown ;;
  esac
}
read_disabled() {  # → DISABLED (" l1 l2 "). vazio (cabeçalho presente, nenhum "=> disabled") → conjunto vazio, rc 0; falhou/ilegível (rc ≠ 0, estouro, sem o cabeçalho "disabled services") → rc 1: sem esta leitura ninguém é parado
  lc print-disabled "gui/$UIDN"; local rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'disabled services' "$RB"; } || return 1
  DISABLED=" $(awk '$2 == "=>" && ($3 == "disabled" || $3 == "true") { gsub(/"/, "", $1); printf "%s ", $1 }' "$RB")"
}
in_disabled() { case "$DISABLED" in *" $1 "*) return 0 ;; esac; return 1; }

read_free() {  # → FREE (MB). vazio (df sem a linha do volume) → rc 1; falhou/ilegível/outro volume → rc 1: NUNCA vira "tem bastante" nem "disco baixo" (quem chama sai 30)
  local v
  if [ -n "${D35_FREE_MB_FILE:-}" ]; then
    v=$(cat "$D35_FREE_MB_FILE" 2>/dev/null) || return 1
  else
    v=$("$DF_BIN" -Pm "$VOLUME" 2>/dev/null) || return 1
    v=$(printf '%s\n' "$v" | awk -v vol="$VOLUME" 'NR == 2 && $4 ~ /^[0-9]+$/ && $NF == vol { print $4; ok = 1 } END { exit ok ? 0 : 1 }') || return 1
  fi
  isnum "$v" || return 1
  FREE=$v
}

valid_row() { case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac; case "$2" in -) ;; ''|*[!0-9]*) return 1 ;; esac; return 0; }
load_allowlist() {  # → ROWS (label TAB porta TAB nome TAB risco, uma por linha), SKIP_N. vazio (nenhuma linha válida) → rc 1; falhou/ilegível (ausente, pasta, sem leitura) → rc 1: quem chama sai 30 e nada é parado
  ROWS=""; SKIP_N=0
  if [ ! -f "$ALLOW" ] || [ ! -r "$ALLOW" ]; then WHY="allowlist ilegível ($ALLOW)"; return 1; fi
  local label porta nome risco rest
  while IFS="$TAB" read -r label porta nome risco rest || [ -n "$label" ]; do
    case "$label" in ''|'#'*) continue ;; esac
    if [ -z "${risco:-}" ] || [ -n "${rest:-}" ] || ! valid_row "$label" "$porta"; then SKIP_N=$((SKIP_N + 1)); log "linha IGNORADA (malformada): $label"; continue; fi
    if denied "$label" "$porta"; then SKIP_N=$((SKIP_N + 1)); log "linha NEGADA pela deny-list ($DENY_WHY): $label"; continue; fi
    ROWS="$ROWS$label$TAB$porta$TAB$nome$TAB$risco$NL"
  done < "$ALLOW"
  [ -n "$ROWS" ] || { WHY="allowlist sem nenhuma linha válida ($ALLOW)"; return 1; }
}

ev() {  # $1=EVENTO $2=label $3=pid $4=livre $5=detalhe → acrescenta ao registro. rc 1 = não gravou (sem registro NÃO se para: é com ele que o --resume sabe o que religar)
  local d; d=$(printf '%s' "${5:--}" | tr '\t\n' '  ')
  { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$1" "$2" "${3:--}" "${4:--}" "$d" >> "$STATE"; } 2>/dev/null
}
read_registry() {  # → PENDING (seq TAB label TAB pid, o mais recente primeiro), LAST_CUT (epoch do último STOPPED), FAILED (STOP_FAILED há < FAIL_COOL_S).
  PENDING=""; LAST_CUT=0; FAILED=" "
  # vazio (arquivo ausente) → nada pendente, nenhum corte; falhou/ilegível (existe e não é arquivo legível, awk com erro) → rc 1; linha que não tem 6 campos é ruído e é ignorada
  [ -e "$STATE" ] || return 0
  { [ -f "$STATE" ] && [ -r "$STATE" ]; } || return 1
  local out kind a b c
  out=$(awk -F'\t' -v now="$NOW" -v cool="$FAIL_COOL_S" '
    NF >= 6 && $1 ~ /^[0-9]+$/ { last[$3] = $2; seq[$3] = NR; pid[$3] = $4; at[$3] = $1; if ($2 == "STOPPED" && $1 + 0 > cut) cut = $1 + 0 }
    END { for (l in last) {
            if (last[l] == "STOPPING" || last[l] == "STOPPED" || last[l] == "RESUME_FAILED") printf "P\t%d\t%s\t%s\n", seq[l], l, pid[l]
            else if (last[l] == "STOP_FAILED" && now >= at[l] && now - at[l] < cool) printf "F\t%s\n", l }
          printf "C\t%d\n", cut }' "$STATE") || return 1
  while IFS="$TAB" read -r kind a b c; do
    case "$kind" in
      P) PENDING="$PENDING$a$TAB$b$TAB$c$NL" ;;
      F) FAILED="$FAILED$a " ;;
      C) LAST_CUT=$a ;;
    esac
  done <<EOF
$out
EOF
  PENDING=$(printf '%s' "$PENDING" | sort -t"$TAB" -k1,1nr)   # ordem do ARQUIVO (cortes da mesma rodada têm o mesmo epoch)
}

take_lock() {  # rc 0 = peguei · 1 = OUTRA instância viva · 2 = não consegui tomar nem verificar (terceiro estado: dono ilegível, ps que falha). O dono é conferido pela LINHA DE COMANDO, não só pelo pid (pid reaproveitado não prende)
  local p c
  mkdir -p "$(dirname "$LOCKD")" 2>/dev/null || return 2
  if ! mkdir "$LOCKD" 2>/dev/null; then
    # vazio/falhou/ilegível (sem pid, lixo) → rc 2 (não sei se há outra instância); com pid: vivo E linha de comando de um D3.5 → rc 1; ps que falha → rc 2
    p=$(cat "$LOCKD/pid" 2>/dev/null); isnum "$p" || return 2
    if kill -0 "$p" 2>/dev/null; then
      c=$("$PS_BIN" -p "$p" -o command= 2>/dev/null) || return 2
      case "$c" in *disk-recovery-d35*) return 1 ;; esac
    fi
    rm -f "$LOCKD/pid" 2>/dev/null; rmdir "$LOCKD" 2>/dev/null; mkdir "$LOCKD" 2>/dev/null || return 2
  fi
  LOCK_HELD=1
  { printf '%s\n' "$$" > "$LOCKD/pid"; } 2>/dev/null || return 2
}
high_timer() {  # → HELD = segundos seguidos com livre >= RESUME_ABOVE_MB, contando só o que EU vi. vazio (sem arquivo) → começa agora; falhou/ilegível (lixo, relógio andou para trás, lacuna > GAP_S entre duas leituras) → começa agora
  # (o lado inerte: não retoma antes da hora). rc 1 = não consegui gravar o relógio
  local since="" seen=""
  [ -r "$HIGH" ] && read -r since seen < "$HIGH" 2>/dev/null
  case "$since" in ''|*[!0-9]*) since=$NOW ;; esac
  case "$seen" in ''|*[!0-9]*) since=$NOW; seen=$NOW ;; esac
  { [ "$since" -le "$NOW" ] && [ "$seen" -le "$NOW" ] && [ $((NOW - seen)) -le "$GAP_S" ]; } || since=$NOW
  { printf '%s %s\n' "$since" "$NOW" > "$HIGH"; } 2>/dev/null || return 1
  HELD=$((NOW - since))
}

undo_stop() {  # $1=label $2=pid: enable (idempotente) e RELÊ; só com a prova vira STOP_FAILED, senão INCONSISTENTE (o registro continua STOPPING = pendente, o --resume o religa)
  lc enable "gui/$UIDN/$1"
  if read_disabled && ! in_disabled "$1"; then ev STOP_FAILED "$1" "$2" "$FREE" "$STOPERR"; return 1; fi
  STOPERR="INCONSISTENTE: $STOPERR e não consegui desfazer o disable"; return 1
}
stop_one() {  # $1=label $2=pid ("-" = sem pid) → rc 0 = parado e PROVADO (sumiu do launchd) · 1 = falhou (STOPERR diz o motivo e se o disable foi desfeito ou ficou INCONSISTENTE) · 3 = não gravei o registro (nada foi feito)
  local l=$1 p=$2 i=0
  STOPERR=""
  ev STOPPING "$l" "$p" "$FREE" "disable+bootout" || { STOPERR="não gravei o registro"; return 3; }
  lc disable "gui/$UIDN/$l"
  # a prova do disable é relê-lo; falhou/ilegível = não está provado: desfaz
  if ! read_disabled || ! in_disabled "$l"; then STOPERR="disable não pegou"; undo_stop "$l" "$p"; return $?; fi
  lc bootout "gui/$UIDN/$l"
  while :; do lc_state "$l"; [ "$ST" = unloaded ] && break; [ "$i" -ge "$STOP_WAIT_S" ] && break; sleep 1; i=$((i + 1)); done
  if [ "$ST" = unloaded ]; then ev STOPPED "$l" "$p" "$FREE" "disabled+unloaded" || log "WARN: STOPPED de $l não gravado (o STOPPING já o deixa pendente)"; return 0; fi
  # vazio → n/a (a prova é o rc do print); falhou/ilegível (print ≠ 0/113, estouro) → NÃO sei se saiu: desfazer às cegas deixaria o serviço parado sem registro; fica STOPPING (pendente) e o --resume resolve
  if [ "$ST" = unknown ]; then STOPERR="INCONSISTENTE: não consegui provar o bootout de $l (launchctl print ilegível); o registro o deixa pendente"; return 1; fi
  STOPERR="bootout não tirou $l do launchd (estado $ST)"; undo_stop "$l" "$p"
}
resume_one() {  # $1=label $2=pid de quando parei ("-" = sem pid) → rc 0 = religado e PROVADO (RESUME_PID) · 1 = falhou (RESUME_FAILED: continua pendente; STOPERR diz por quê)
  local l=$1 old=$2 plist="$PLISTS/$1.plist" i=0 good=0
  STOPERR=""
  if [ ! -f "$plist" ]; then STOPERR="sem plist ($plist)"; ev RESUME_FAILED "$l" "$old" "$FREE" "$STOPERR"; return 1; fi
  lc enable "gui/$UIDN/$l"
  lc bootstrap "gui/$UIDN" "$plist"
  while :; do
    lc_state "$l"
    if [ "$ST" = loaded ]; then
      if [ "$old" = - ]; then good=1; else case "$PID" in ''|"$old") ;; *) good=1 ;; esac; fi
    fi
    [ "$good" = 1 ] && break; [ "$i" -ge "$WATCH_S" ] && break; sleep 1; i=$((i + 1))
  done
  if [ "$good" = 1 ]; then RESUME_PID=${PID:--}; ev RESUMED "$l" "$RESUME_PID" "$FREE" "pid antigo $old" || log "WARN: RESUMED de $l não gravado"; return 0; fi
  STOPERR="sem pid novo (estado $ST, pid ${PID:--}, ao parar $old)"; ev RESUME_FAILED "$l" "$old" "$FREE" "$STOPERR"; return 1
}

do_run() {
  load_allowlist || finish 30 "$WHY: NÃO paro nada"
  read_registry || finish 30 "registro ilegível ($STATE): NÃO paro nada"
  read_free || finish 30 "não consegui ler o disco: NÃO paro nada"
  [ "$FREE" -lt "$STOP_BELOW_MB" ] || finish 10 "disco ok (livre=${FREE}MB >= ${STOP_BELOW_MB}MB): nada a cortar"
  if [ "$LAST_CUT" -gt 0 ] && [ "$NOW" -ge "$LAST_CUT" ] && [ $((NOW - LAST_CUT)) -lt "$SPACING_S" ]; then
    finish 12 "esperando o efeito do último corte (há $((NOW - LAST_CUT))s, < ${SPACING_S}s); livre=${FREE}MB"
  fi
  read_disabled || finish 30 "não consegui ler os labels desabilitados (launchctl print-disabled): NÃO paro nada"
  local label porta nome risco src pid0 before=$FREE cut=0 fail=0 unread=0 alheio=0 semplist=0 tried=0 meas=0 list="" failtxt="" txt rc=0 neg=""
  while IFS="$TAB" read -r label porta nome risco; do
    [ -n "$label" ] || continue
    [ "$cut" -lt "$MAX_PER_RUN" ] || break
    [ "$tried" -eq 0 ] || [ "$SECONDS" -lt "$BUDGET_S" ] || break
    case "$FAILED" in *" $label "*) continue ;; esac
    if in_disabled "$label"; then alheio=$((alheio + 1)); continue; fi
    if [ ! -f "$PLISTS/$label.plist" ]; then semplist=$((semplist + 1)); continue; fi
    lc_state "$label"
    case "$ST" in loaded) ;; unloaded) continue ;; *) unread=$((unread + 1)); continue ;; esac
    if [ "$DRY" = 1 ]; then cut=$((cut + 1)); list="$list${list:+, }$nome [$label]"; continue; fi
    tried=$((tried + 1)); pid0=${PID:--}   # o lc_state da prova (dentro do stop_one) zera o PID: guardo o de antes
    stop_one "$label" "$pid0"; src=$?
    if [ "$src" -ne 0 ]; then
      fail=$((fail + 1)); failtxt="$failtxt${failtxt:+; }$label ($STOPERR)"; log "FALHOU $label: $STOPERR"
      continue
    fi
    cut=$((cut + 1)); list="$list${list:+, }$nome [$label]"; log "parei $label (pid $pid0)"
    [ "$SETTLE_S" -gt 0 ] && sleep "$SETTLE_S"
    # re-mede depois de cada corte e PARA quando o livre voltou a >= limiar; falhou/ilegível → para por aqui (não corta mais às cegas)
    read_free || { meas=1; break; }
    [ "$FREE" -lt "$STOP_BELOW_MB" ] || break
  done <<EOF
$ROWS
EOF
  [ "$SKIP_N" -eq 0 ] || neg="; $SKIP_N negada(s)/ignorada(s) (deny-list ou linha malformada)"
  if [ "$cut" -eq 0 ] && [ "$fail" -eq 0 ]; then
    [ "$unread" -eq 0 ] || finish 30 "não consegui ler o estado de $unread label(s) no launchd (print): NÃO sei se a lista esgotou$neg"
    finish 11 "lista esgotada: nada mais a parar ($alheio desligado(s) por decisão alheia, $semplist sem plist; os já parados por mim ficam no registro); livre=${FREE}MB < ${STOP_BELOW_MB}MB$neg"
  fi
  if [ "$DRY" = 1 ]; then finish 0 "pararia $cut: $list; livre=${FREE}MB$neg"; fi
  txt="parei $cut"; [ "$cut" -eq 0 ] || txt="$txt: $list"
  txt="$txt; livre $before -> $FREE MB"
  [ "$fail" -eq 0 ] || { txt="$txt; FALHOU $fail: $failtxt"; rc=20; }
  [ "$meas" -eq 0 ] || txt="$txt; re-medição do disco falhou (paro por aqui)"
  [ "$unread" -eq 0 ] || txt="$txt; $unread label(s) sem leitura no launchd"
  finish "$rc" "$txt$neg"
}

do_resume() {
  read_registry || finish 30 "registro ilegível ($STATE): NÃO retomo nada"
  [ -n "$PENDING" ] || { rm -f "$HIGH" 2>/dev/null; finish 10 "nada a retomar"; }
  local np seq label pid how aband=0
  np=$(printf '%s\n' "$PENDING" | grep -c .)
  read_free || finish 30 "não consegui ler o disco: NÃO retomo nada"
  if [ "$FREE" -lt "$RESUME_ABOVE_MB" ]; then rm -f "$HIGH" 2>/dev/null; finish 10 "livre=${FREE}MB < ${RESUME_ABOVE_MB}MB: não retomo ($np parado(s))"; fi
  high_timer || finish 30 "não consegui gravar o relógio da retomada ($HIGH): NÃO retomo nada"
  [ "$HELD" -ge "$RESUME_HOLD_S" ] || finish 10 "livre=${FREE}MB >= ${RESUME_ABOVE_MB}MB há ${HELD}s (< ${RESUME_HOLD_S}s): espero ($np parado(s))"
  read_disabled || finish 30 "não consegui ler os labels desabilitados (launchctl print-disabled): NÃO retomo nada"
  while IFS="$TAB" read -r seq label pid; do
    [ -n "$label" ] || continue
    lc_state "$label"
    case "$ST" in
      loaded)
        if in_disabled "$label"; then   # corte pela metade (carregado e desabilitado: o disable ficou e o bootout não): só falta o enable, e é RELIDO
          lc enable "gui/$UIDN/$label"
          if read_disabled && ! in_disabled "$label"; then
            ev RESUMED "$label" "${PID:--}" "$FREE" "enable (já carregado)" || log "WARN: RESUMED de $label não gravado"
            finish 0 "religou [$label] (re-habilitado: já estava carregado, só o disable tinha ficado); restam $((np - 1 - aband))"
          fi
          ev RESUME_FAILED "$label" "$pid" "$FREE" "enable não pegou" || log "WARN: RESUME_FAILED de $label não gravado"
          finish 20 "FALHOU ao re-habilitar [$label]: o enable não pegou (continua pendente)"
        fi
        ev ABANDONED "$label" "$pid" "$FREE" "já carregado por outro" || log "WARN: ABANDONED de $label não gravado"; aband=$((aband + 1)); continue ;;
      unloaded) ;;
      *) finish 30 "não consegui ler o estado de $label no launchd: NÃO retomo" ;;
    esac
    if resume_one "$label" "$pid"; then
      how="sem pid antes; carregado"; [ "$pid" = - ] || how="pid $pid -> $RESUME_PID"
      finish 0 "religou [$label] ($how); restam $((np - 1 - aband))"
    fi
    finish 20 "FALHOU ao religar [$label]: $STOPERR (continua pendente)"
  done <<EOF
$PENDING
EOF
  finish 10 "nada a retomar ($aband já carregado(s) por outro)"
}

case "${1:-}" in --run) MODE=run ;; --dry-run) MODE=dry-run; DRY=1 ;; --resume) MODE=resume ;; *) usage ;; esac
[ "$#" -eq 1 ] || usage
trap on_exit EXIT
# vazio/falhou/ilegível (date sem resposta) → NOW vazio → sai 30: sem hora não há relógio de retomada nem ritmo do corte
NOW=$(now); isnum "$NOW" || finish 30 "relógio ilegível: não decido nada"
[ ! -e "$OFF" ] || finish 10 "interruptor ligado ($OFF): não leio, não ajo"
if [ "$DRY" != 1 ]; then
  take_lock; lrc=$?
  case "$lrc" in 0) ;; 1) finish 10 "outra instância em execução ($LOCKD)" ;; *) finish 30 "não consegui tomar nem verificar a trava ($LOCKD)" ;; esac
fi
case "$MODE" in resume) do_resume ;; *) do_run ;; esac
