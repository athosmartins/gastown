#!/bin/bash
# disk-recovery-d2-heavy-jobs.sh — degrau D2 da escada de recuperação de disco do mini (ga-1p1i5jr.2, missão ga-1p1i5jr).
#
# ## Contents
#   Para que serve · Uso · Contrato (saída e códigos) · A allowlist · O que o rfb ensina · O registro do que foi parado · Retomar · Guardas · Variáveis · Teste
#
# PARA QUE SERVE. A escada (ga-1p1i5jr.1, scripts/disk-recovery-ladder.sh) chama este degrau quando o livre do volume de dados ficou <= 5 GB por 15 min: D1 (limpar
# arquivo) já tentou. Aqui se PARA, e só se para, jobs pesados e reiniciáveis que estão na ALLOWLIST (scripts/disk-recovery-d2-allowlist.tsv). Memória pesada vira
# swap e o swap sai do MESMO disco (01/11: disco 2 GB, swap 4,8 GB de 6 GB) — soltar a pegada de um lote de horas libera o disco sem apagar nada de ninguém.
# Decisão do Athos para a escada (citável): AskUserQuestion na sessão do Mayor, 01/11/2026 ~11:00 BRT, "A qualquer hora, com guardas (Recomendado)".
#
# USO
#   disk-recovery-d2-heavy-jobs.sh --dry-run   só diz o que faria. Não toma trava, não grava estado nem log, não lê o S3, não chama launchctl.
#   disk-recovery-d2-heavy-jobs.sh --run       real: para o que a allowlist manda parar e anota o que parou.
#   disk-recovery-d2-heavy-jobs.sh --resume    ADITIVO (fora do contrato da escada): retoma o que o --run parou, quando o disco voltou. Seguro de repetir a cada tick.
#
# CONTRATO (o do Mayor + o do orquestrador dog-2). stdout: UMA linha, sempre ("D2 --run: ..."). Códigos de saída:
#   0   agiu e terminou     (--run: parou ao menos um e todos morreram · --resume: lançou a retomada)
#   10  nada a fazer, ou uma guarda adiou (nada rodando · rodando mas o livre está acima do piso de parada do job · outra instância em execução · retomar ainda não pode: disco, janela, o job recusou)
#   20  falhou              (não conseguiu gravar o registro, o processo não morreu ou a morte não foi comprovada, a retomada não subiu, erro interno)
#   30  não consegui ler o estado e por isso NÃO agi (df, ps, allowlist, registro, plist ou launchctl list ilegíveis; ps ilegível na re-conferência antes do primeiro sinal; não consegui criar nem verificar a trava; regex larga demais;
#       --resume: não consegui apagar o código de saída da retomada anterior)
#   --dry-run devolve os mesmos códigos como previsão (0 = agiria). Quem avisa o Athos (notify/mail em 0/20) é o orquestrador: este degrau só escreve o próprio log.
#
# A ALLOWLIST. Casa por REGEX contra a linha de comando do processo E a do PAI (o job de verdade tem o pai do launchd), nunca por tamanho de memória. O arquivo é
# a documentação viva: por linha, o piso de PARADA, o piso de RETOMADA, a janela e o COMO. Nele também estão, comentados, os candidatos REJEITADOS e por quê.
#
# O QUE O RFB ENSINA (a pergunta do bead: retoma do ponto ou do zero?). Por TABELA: a que terminou e foi verificada tem checkpoint no S3 e é reaproveitada; a que estava
# em andamento recomeça do ZERO (horas). Por isso o piso de parada do rfb é 3 GB (não os 5 GB em que o D2 é chamado): acima disso o D2 devolve 10 e deixa o job
# terminar a tabela. O tick das 00:15 seguinte começa um run NOVO — a retomada tem de vir antes dele, e este script é quem a faz.
#
# O REGISTRO DO QUE FOI PARADO. $D2_STATE (padrão $CITY/.gc/disk-recovery-d2.state), TSV de eventos, só acrescenta:
#   epoch  EVENTO  id  pid  início_epoch  run_id  livre_MB  detalhe          (campo vazio = `-`)
#   STOPPING (gravado ANTES do kill) → STOPPED (morreu; carrega o run_id: o `--resume-run <id>` da linha de comando do job, se ele era uma retomada, senão o lido do S3) | STOP_FAILED
#   RESUME_STARTED · RESUME_REFUSED (o próprio job disse "não rodei": segue pendente) · RESUME_FAILED · ABANDONED (velho demais, saiu da allowlist, já há outro processo)
#   "Pendente de retomada" = o último evento do id é STOPPING, STOPPED ou RESUME_REFUSED.
#
# RETOMAR (--resume). Só retoma o pendente se: o livre >= resume_above_mb do job; está na janela dele; não há processo do job rodando; o run não passou de resume_max_age_s;
# e o run_id é LIDO (do registro, da linha de comando do job retomado ou do S3, casando pid + hora de início do processo parado) e tem a forma `<epoch>-<pid>` — NUNCA adivinhado. Lança via
# `launchctl submit` (fora deste processo, para não morrer com o orquestrador) com o MESMO ambiente do plist do job (teto de memória e de RSS inclusos) e vigia
# $D2_RESUME_WATCH_S s: se o job seguir de pé, é 0 (isso NÃO prova que passou dos portões dele — origem, checkpoints no S3 e mês rodam depois, e o D2 para de olhar ali); se o portão dele recusar
# (rc 3 "NÃO RODEI": janela, disco 8,25 GiB, outro processo), é 10 e segue pendente. O RÓTULO da retomada: `submit` é KeepAlive (o launchd relança o job ~10 s depois de TODA saída), então o job roda dentro de
# um wrapper que, ao fim, grava o código de saída em .gc/disk-recovery-d2-resume-rfb.rc e REMOVE o próprio rótulo — ele vive só enquanto o job vive, e um job que a escada parou de novo (TERM) não volta sozinho.
# O arquivo de código é apagado antes de cada lançamento (se não der: rc 30, nada é lançado) e um wrapper relançado por um `remove` que falhou NÃO roda o job outra vez.
# QUEM CHAMA --resume: a escada chama o D2 só no aperto, então algo tem de chamá-lo quando o disco volta (tick do orquestrador ou um agendador próprio). Sem chamador,
# o job fica parado até o tick das 00:15, que recomeça do zero.
#
# GUARDAS. (1) só mexe em processo da allowlist, do MEU usuário, com o pai certo, e re-confere a identidade logo antes do TERM e de novo logo antes do KILL (pid reaproveitado
# não recebe sinal; resta só a janela de milissegundos entre a checagem e o kill); (2) "não consegui medir" nunca vira "disco baixo" nem "disco bom": é rc 30 e não age; (3) o registro é gravado ANTES do kill — sem registro, não para;
# (4) TERM primeiro (SIGINT não serve: sob launchd o filho de `&` o herda ignorado), KILL só depois da graça e só se o processo ainda for o job; morte comprovada
# por ps E por kill -0, não suposta (ps ilegível, ou pid vivo que não casa mais com a allowlist = "não provei", rc 20, sem KILL às cegas); (5) regex que casa mais de $D2_MAX_MATCH processos =
# regex larga demais: rc 30, nada é tocado; (6) instância única por trava (mkdir): o dono é conferido pela LINHA DE COMANDO, não só pelo pid (pid reaproveitado não prende o D2).
#
# VARIÁVEIS (todas opcionais; as de TESTE estão marcadas). D2_CITY D2_ALLOWLIST D2_STATE D2_LOG D2_LOCK D2_VOLUME D2_TERM_GRACE_S D2_KILL_WAIT_S D2_MAX_MATCH D2_S3_TIMEOUT_S
# D2_RESUME_WATCH_S D2_RFB_ROOT D2_RFB_PYTHON D2_RFB_PLIST D2_RFB_META_URI D2_LOCK_WAIT_S · binários: D2_PS_BIN D2_DF_BIN D2_AWS_BIN D2_LAUNCHCTL_BIN D2_PYTHON3_BIN · TESTE: D2_FREE_MB D2_NOW D2_HOUR D2_LOCKPS_BIN.
# TESTE: bash scripts/disk-recovery-d2-heavy-jobs.selftest.sh   (hermético: processos de brinquedo, ps/df/aws/launchctl simulados; nada real é parado; bateria de mutantes inclusa).
#
# bash 3.2 (o /bin/bash do macOS): sem declare -A, mapfile, ${v,,}.
set -uo pipefail
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

D=$(cd "$(dirname "$0")" && pwd)
CITY="${D2_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
ALLOW="${D2_ALLOWLIST:-$D/disk-recovery-d2-allowlist.tsv}"
STATE="${D2_STATE:-$GCDIR/disk-recovery-d2.state}"
LOG="${D2_LOG:-$GCDIR/logs/disk-recovery-d2.log}"
LOCKD="${D2_LOCK:-$GCDIR/disk-recovery-d2.lock.d}"
VOLUME="${D2_VOLUME:-/System/Volumes/Data}"
PS_BIN="${D2_PS_BIN:-ps}"
LOCKPS_BIN="${D2_LOCKPS_BIN:-ps}"   # só para conferir o dono da trava (pid → linha de comando); o teste troca por um que falha
DF_BIN="${D2_DF_BIN:-df}"
AWS_BIN="${D2_AWS_BIN:-aws}"
LAUNCHCTL_BIN="${D2_LAUNCHCTL_BIN:-launchctl}"
PYTHON3_BIN="${D2_PYTHON3_BIN:-/usr/bin/python3}"
RFB_ROOT="${D2_RFB_ROOT:-/Users/athos/gt/whatsapp_automation}"
RFB_PYTHON="${D2_RFB_PYTHON:-/opt/homebrew/bin/python3}"
RFB_PLIST="${D2_RFB_PLIST:-$HOME/Library/LaunchAgents/com.whatsapp.rfb-monthly-refresh.plist}"
RFB_META_URI="${D2_RFB_META_URI:-s3://urblink-motherduck-backups/real_estate/rfb/_meta/}"
RESUME_LABEL="com.gascity.d2-resume.rfb"
RESUME_LOG="$GCDIR/logs/disk-recovery-d2-resume-rfb.log"
RESUME_RC="$GCDIR/disk-recovery-d2-resume-rfb.rc"      # o código de saída da ÚLTIMA retomada, gravado pelo wrapper abaixo quando o job acaba (o rótulo some junto)
# O que o launchd roda na retomada: um `bash -c` (parâmetros: arquivo-de-rc rótulo launchctl raiz comando...). `launchctl submit` cria um job KeepAlive — o launchd o RELANÇA ~10 s depois de TODA
# saída, qualquer que seja o código (medido pelo revisor do gate, ga-1p1i5jr.2.1) —, então o job que acaba depois da vigia rodaria de novo sem parar, e o job que a escada parou (TERM) voltaria sozinho.
# Por isso o job roda como FILHO e o wrapper, ao fim, grava o código em $RESUME_RC e REMOVE o próprio rótulo (o remove pode terminar o próprio wrapper: o código já está gravado). Se o remove falhar e o launchd relançar o wrapper,
# o arquivo de código já existe: ele só tenta remover de novo e NÃO roda o job outra vez. Tudo em UMA linha: o `ps` não pode ver o corpo quebrado em várias linhas.
RESUME_WRAPPER='rcf=$1; lab=$2; lc=$3; root=$4; shift 4; [ -e "$rcf" ] && { "$lc" remove "$lab"; exit 0; }; ( cd "$root" && exec "$@" ); rc=$?; printf "%s\n" "$rc" >"$rcf"; "$lc" remove "$lab"; exit "$rc"'      # MUT:wrapper
MYUID=$(id -u)
TAB=$(printf '\t')
NL='
'

num() {  # $1=nome $2=padrão → só dígitos, até 9; lixo cai no padrão
  local v; eval "v=\${$1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "${#v}" -le 9 ] || v=$2
  printf '%s' "$v"
}
TERM_GRACE_S=$(num D2_TERM_GRACE_S 20)
KILL_WAIT_S=$(num D2_KILL_WAIT_S 5)
MAX_MATCH=$(num D2_MAX_MATCH 3)
S3_TIMEOUT_S=$(num D2_S3_TIMEOUT_S 40)
LOCK_WAIT_S=$(num D2_LOCK_WAIT_S 2)
WATCH_S=$(num D2_RESUME_WATCH_S 25)

MODE=""; DRY=0; DONE=0; LOCK_HELD=0; RB=""

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() {  # só no modo real: o --dry-run não escreve nada em disco
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  printf '%s D2 %s: %s\n' "$(ts)" "${MODE:-?}" "$*" >>"$LOG" 2>/dev/null || true
}
cleanup() {
  [ -n "$RB" ] && rm -f "$RB" 2>/dev/null
  [ "$LOCK_HELD" = 1 ] && rm -rf "$LOCKD" 2>/dev/null
  return 0
}
finish() {  # $1=rc $2=texto → UMA linha no stdout e sai
  DONE=1
  local line="D2 ${MODE:-?}: $2"
  log "FIM rc=$1: $2"
  printf '%s\n' "$line"
  cleanup
  exit "$1"
}
on_exit() {
  local rc=$?
  if [ "$DONE" != 1 ]; then
    DONE=1; log "ERRO INTERNO rc=$rc (o script saiu sem concluir)"
    printf 'D2 %s: erro interno (rc=%s); não sei se agiu; ver %s\n' "${MODE:-?}" "$rc" "$LOG"
    cleanup; exit 20
  fi
}
trap on_exit EXIT

now() {
  local v="${D2_NOW:-}"
  case "$v" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$v" ;; esac
}
hour_now() {
  local v="${D2_HOUR:-}"
  case "$v" in ''|*[!0-9]*) date +%H ;; *) printf '%s' "$v" ;; esac
}

read_free_mb() {  # stdout: MB livres no volume de dados; rc 1 = não consegui ler (nunca imprime 0 no lugar do erro)
  local v="${D2_FREE_MB:-}" out
  if [ -n "$v" ]; then
    case "$v" in *[!0-9]*) return 1 ;; esac
    printf '%s' "$v"; return 0
  fi
  out=$("$DF_BIN" -Pk "$VOLUME" 2>/dev/null) || return 1      # MUT:dfread
  printf '%s\n' "$out" | awk 'NR==2 && $4 ~ /^[0-9]+$/ { printf "%d", $4/1024; ok=1 } END { exit ok ? 0 : 1 }'      # MUT:dfparse
}

run_bounded() {  # $1=segundos, resto=comando; stdout do comando em $RB; rc do comando ou 124 se estourou
  local secs=$1 pid i=0 max; shift
  max=$((secs * 5))
  [ -n "$RB" ] || RB=$(mktemp "${TMPDIR:-/tmp}/d2-rb.XXXXXX") || return 125
  "$@" >"$RB" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then
      kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2; i=$((i + 1))
  done
  wait "$pid"
}

find_procs() {  # $1=match_regex $2=parent_regex → linhas "pid<TAB>uid<TAB>ppid<TAB>etime_s<TAB>comando"; rc 0 = li (pode ser vazio), rc 1 = ps ilegível
  local out
  out=$("$PS_BIN" -axww -o pid=,ppid=,uid=,etime=,command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | RE="$1" PRE="$2" SELF="$$" SELFP="$PPID" ME="$MYUID" awk '
    function secs(e,   d, p, n, t) {
      d = 0
      if (e ~ /-/) { split(e, p, "-"); d = p[1] + 0; e = p[2] }
      n = split(e, t, ":")
      if (n == 3) return d * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
      if (n == 2) return d * 86400 + t[1] * 60 + t[2]
      return -1
    }
    { pid = $1; ppid = $2; uid = $3; et = $4; c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +[^ ]+ +/, "", c)
      cmd[pid] = c; PP[pid] = ppid; U[pid] = uid; E[pid] = et; n++; order[n] = pid }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (p == ENVIRON["SELF"] || p == ENVIRON["SELFP"] || U[p] != ENVIRON["ME"]) continue
        if (cmd[p] ~ /disk-recovery-d2/) continue
        if (cmd[p] ~ ENVIRON["RE"] && cmd[PP[p]] ~ ENVIRON["PRE"]) printf "%s\t%s\t%s\t%d\t%s\n", p, U[p], PP[p], secs(E[p]), cmd[p]   # MUT:parent
      }
    }'
}

pid_listed() {  # $1=match $2=parent $3=pid → rc 0 = ainda é o job vivo, 1 = não está (morreu ou o pid é de outro), 2 = ps ilegível
  local o
  o=$(find_procs "$1" "$2") || return 2
  printf '%s\n' "$o" | awk -F'\t' -v p="$3" '$1 == p { f = 1 } END { exit f ? 0 : 1 }'
}

pid_gone() {  # $1=pid → rc 0 = o processo não existe mais (ou virou zumbi) · 1 = ainda existe, ou não consegui provar que sumiu
  local st
  kill -0 "$1" 2>/dev/null || return 0                      # ESRCH (ou pid de outro usuário: o nosso sumiu)
  # vazio → o ps não lista o pid; falhou/ilegível → idem: as duas coisas dão "não provei" (rc 1), nunca "sumiu"
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  case "$st" in Z*) return 0 ;; esac
  return 1
}

stop_pid() {  # $1=match $2=parent $3=pid → rc 0 = morreu (comprovado: fora da allowlist no ps E sem processo/zumbi) · 1 = vivo depois de TERM+KILL · 2 = NÃO provei (ps ilegível, ou o pid vive sem casar mais com a allowlist): não mando KILL às cegas
  local re=$1 pre=$2 pid=$3 i=0 max r
  kill -TERM "$pid" 2>/dev/null
  max=$((TERM_GRACE_S * 5))
  while [ "$i" -lt "$max" ]; do
    pid_listed "$re" "$pre" "$pid"; r=$?
    [ "$r" -eq 1 ] && pid_gone "$pid" && return 0      # MUT:pidgone
    sleep 0.2; i=$((i + 1))
  done
  pid_listed "$re" "$pre" "$pid"; r=$?
  if [ "$r" -eq 1 ]; then pid_gone "$pid" && return 0; fi
  [ "$r" -eq 0 ] || return 2                      # MUT:killunknown
  log "pid $pid sobreviveu à graça de ${TERM_GRACE_S}s depois do TERM: KILL"
  kill -KILL "$pid" 2>/dev/null                   # MUT:killescalate
  i=0; max=$((KILL_WAIT_S * 5))
  while [ "$i" -lt "$max" ]; do
    pid_listed "$re" "$pre" "$pid"; r=$?
    [ "$r" -eq 1 ] && pid_gone "$pid" && return 0
    sleep 0.2; i=$((i + 1))
  done
  [ "$r" -eq 0 ] && return 1
  return 2
}

lock_owner() {  # $1=pid → rc 0 = o dono vive E é um D2 · 1 = morto, ou o pid é de outro programa (reaproveitado) · 2 = não consegui ver (a trava fica)
  local c prc
  kill -0 "$1" 2>/dev/null || return 1
  # vazio → o pid sumiu entre o kill e o ps = dono morto (1); falhou/ilegível (rc >= 2, ex. binário ausente) → não sei (2): não roubo a trava
  c=$("$LOCKPS_BIN" -o command= -p "$1" 2>/dev/null); prc=$?
  [ "$prc" -le 1 ] || return 2
  case "$c" in *disk-recovery-d2*) return 0 ;; esac      # MUT:lockowner
  return 1
}

acquire_lock() {  # rc 0 = tomei · 1 = outra instância (viva, ou começando agora) · 2 = não consegui criar nem verificar a trava (NÃO é "outra instância")
  local p i max o old try
  mkdir -p "$(dirname "$LOCKD")" 2>/dev/null || return 2
  for try in 1 2; do
    if mkdir "$LOCKD" 2>/dev/null; then
      printf '%s' "$$" >"$LOCKD/pid" 2>/dev/null || { rm -rf "$LOCKD" 2>/dev/null; return 2; }
      LOCK_HELD=1; return 0
    fi
    p=""; i=0; max=$((LOCK_WAIT_S * 5))
    # vazio → o dono criou a pasta e ainda não gravou o pid: espero até D2_LOCK_WAIT_S e depois julgo pela idade; falhou/ilegível → idem (sem pid legível): só a idade (> 2 min) a torna abandonada
    while [ "$i" -le "$max" ]; do p=$(cat "$LOCKD/pid" 2>/dev/null); [ -n "$p" ] && break; sleep 0.2; i=$((i + 1)); done
    [ -d "$LOCKD" ] || continue                       # o dono terminou e soltou a trava enquanto eu esperava: tento tomar de novo
    if [ -n "$p" ]; then
      lock_owner "$p"; o=$?
      [ "$o" -eq 0 ] && return 1
      [ "$o" -eq 1 ] || return 2      # MUT:lockunknown
    else
      # sem pid depois da espera: só é trava abandonada se a pasta tem mais de 2 min; idade ilegível = não sei = não toco; pasta nova = o dono está começando
      old=$(find "$LOCKD" -maxdepth 0 -mmin +2 2>/dev/null) || return 2
      [ -n "$old" ] || return 1      # MUT:lockyoung
    fi
    rm -rf "$LOCKD" 2>/dev/null
  done
  [ -d "$LOCKD" ] && return 1
  return 2
}

trim_log() {  # o log não cresce sem fim: acima de 512 KB fica com as últimas 2000 linhas
  [ -f "$LOG" ] || return 0
  local kb; kb=$(( $(wc -c <"$LOG" 2>/dev/null || echo 0) / 1024 ))
  [ "$kb" -gt 512 ] || return 0
  tail -n 2000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  return 0
}

state_append() {  # EVENTO id pid início_epoch run_id livre_MB detalhe → rc 1 se não gravou (quem chama decide; "sem registro, não para")
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "${3:--}" "${4:--}" "${5:--}" "${6:--}" \
    "$(printf '%s' "${7:-}" | tr '\t\n' '  ' | cut -c1-300)" >>"$STATE" 2>/dev/null
}

load_allowlist() {  # preenche ROWS (linhas validadas, 9 colunas TAB); rc 1 + ALLOW_ERR se ilegível/inválida
  ROWS=""; ALLOW_ERR=""
  [ -r "$ALLOW" ] || { ALLOW_ERR="allowlist ilegível ($ALLOW)"; return 1; }
  local out line e
  out=$(awk -F'\t' '
    /^[[:space:]]*$/ { next }
    /^#/ { next }
    { n++; bad = ""
      if (NF != 9) bad = "esperava 9 colunas separadas por TAB, achei " NF
      else if ($1 !~ /^[a-z0-9][a-z0-9._-]*$/) bad = "id inválido"
      else if ($2 != "rfb") bad = "adapter desconhecido: " $2
      else if ($3 == "" || $3 == "-" || $4 == "" || $4 == "-") bad = "match_regex/parent_regex vazia"
      else if ($5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/) bad = "stop_below_mb/resume_above_mb não numérico"
      else if (($6 + 0) <= ($5 + 0)) bad = "resume_above_mb tem de ser MAIOR que stop_below_mb (histerese)"
      else if ($7 != "-" && $7 !~ /^[0-9]+-[0-9]+$/) bad = "resume_window inválida"
      else if ($8 != "-" && $8 !~ /^[0-9]+$/) bad = "resume_max_age_s inválido"
      else if ($7 != "-") { split($7, w, "-"); if ((w[1] + 0) > 23 || (w[2] + 0) > 24 || w[1] == w[2]) bad = "resume_window fora de 0-24 ou início = fim" }
      if (bad != "") printf "ERR\t%d\t%s\n", NR, bad; else print
    }
    END { if (n == 0) print "ERR\t0\tallowlist sem nenhuma linha ativa" }' "$ALLOW" 2>/dev/null) || { ALLOW_ERR="não consegui ler $ALLOW"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      ERR"$TAB"*) ALLOW_ERR="allowlist inválida: linha ${line#ERR$TAB}"; return 1 ;;
    esac
    local re pre
    re=$(printf '%s' "$line" | cut -f3); pre=$(printf '%s' "$line" | cut -f4)
    printf '' | grep -E -- "$re" >/dev/null 2>&1; e=$?; [ "$e" -le 1 ] || { ALLOW_ERR="regex inválida em $(printf '%s' "$line" | cut -f1)"; return 1; }
    printf '' | grep -E -- "$pre" >/dev/null 2>&1; e=$?; [ "$e" -le 1 ] || { ALLOW_ERR="parent_regex inválida em $(printf '%s' "$line" | cut -f1)"; return 1; }
    ROWS="${ROWS}${line}${NL}"
  done <<EOF
$out
EOF
  [ -n "$ROWS" ] || { ALLOW_ERR="allowlist sem nenhuma linha ativa"; return 1; }
  return 0
}

row_of() { printf '%s' "$ROWS" | awk -F'\t' -v id="$1" '$1 == id { print; exit }'; }

in_window() {  # $1=H1-H2 ("-" = sempre)
  [ "$1" = "-" ] && return 0
  local a=${1%-*} b=${1#*-} h
  h=$(hour_now); a=$((10#$a)); b=$((10#$b)); h=$((10#$h))
  if [ "$a" -lt "$b" ]; then [ "$h" -ge "$a" ] && [ "$h" -lt "$b" ]; else [ "$h" -ge "$a" ] || [ "$h" -lt "$b" ]; fi
}

# ── adapter rfb ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
rfb_run_id() {  # $1=pid $2=início_epoch → RUNID_RES = "ID <id>" | "NONE" | "AMBIGUOUS"; rc 1 = não consegui ler o S3 (sem subshell: o temporário é limpo no cleanup)
  local rc lo hi
  RUNID_RES=""
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac    # sem a hora de início do processo não há como casar o run: não adivinho
  run_bounded "$S3_TIMEOUT_S" "$AWS_BIN" s3 ls "$RFB_META_URI"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  lo=$(( $2 - 5 )); hi=$(( $(now) + 5 ))
  RUNID_RES=$(awk -v pid="$1" -v lo="$lo" -v hi="$hi" '
    $4 ~ /^stream-run-[0-9]+-[0-9]+\./ {
      id = substr($4, 12); sub(/\..*$/, "", id)
      split(id, a, "-")
      if (a[2] == pid && (a[1] + 0) >= lo && (a[1] + 0) <= hi) ids[id] = 1
    }
    END { n = 0; for (k in ids) { n++; one = k }
      if (n == 1) print "ID " one; else if (n == 0) print "NONE"; else print "AMBIGUOUS" }' "$RB") || return 1
  [ -n "$RUNID_RES" ] || return 1
}

rfb_plist_env() {  # stdout: K=V do EnvironmentVariables do plist do job; rc 1 = ilegível/vazio (não chuto o ambiente)
  local out
  out=$("$PYTHON3_BIN" -I -c '
import plistlib, re, sys
d = plistlib.load(open(sys.argv[1], "rb")).get("EnvironmentVariables")
if not isinstance(d, dict) or not d:
    sys.exit(1)
for k, v in d.items():
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) or not isinstance(v, str) or "\n" in v:
        sys.exit(1)
    print(k + "=" + v)' "$RFB_PLIST" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

rfb_launch() {  # $1=run_id → rc 0 = subiu e seguiu vivo (ou já terminou bem) · 10 = o próprio job recusou (rc 3) · 20 = falhou · 30 = não consegui ler/limpar o estado e NÃO lancei. LAUNCH_MSG diz o que houve
  local rid=$1 envl kv lrc i=0 out code lcabs
  LAUNCH_MSG=""
  envl=$(rfb_plist_env) || { LAUNCH_MSG="não consegui ler o EnvironmentVariables de $RFB_PLIST (não chuto o ambiente do job)"; return 30; }
  # vazio (rc 113: o launchd não conhece o rótulo) → não há retomada, segue para o submit; falhou/ilegível (qualquer outro rc) → não sei se já há uma viva: rc 30, não lanço outra por cima
  out=$("$LAUNCHCTL_BIN" list "$RESUME_LABEL" 2>/dev/null); lrc=$?
  case "$lrc" in 0|113) ;; *) LAUNCH_MSG="launchctl list $RESUME_LABEL falhou (rc $lrc): não sei se já há uma retomada viva, não lanço outra"; return 30 ;; esac      # MUT:listfail
  if [ "$lrc" -eq 0 ]; then
    case "$out" in
      *'"PID" = '[0-9]*) LAUNCH_MSG="já existe uma retomada viva ($RESUME_LABEL)"; return 10 ;;
      *) "$LAUNCHCTL_BIN" remove "$RESUME_LABEL" >/dev/null 2>&1 ;;
    esac
  fi
  mkdir -p "$(dirname "$RESUME_LOG")" 2>/dev/null
  # o código de saída de uma retomada ANTERIOR não pode passar pelo desta (nem fazer o wrapper pular o job): apago e confiro que sumiu.
  # vazio (sem arquivo) → segue; falhou/ilegível (o arquivo ficou e não consegui apagá-lo) → rc 30, não lanço
  rm -f "$RESUME_RC" 2>/dev/null      # MUT:rcclear
  [ ! -e "$RESUME_RC" ] || { LAUNCH_MSG="não consegui apagar o código de saída da retomada anterior ($RESUME_RC): não lanço"; return 30; }      # MUT:rccheck
  # o wrapper chama o launchctl pelo CAMINHO ABSOLUTO: o PATH do job é o do plist do rfb e pode não ter /bin, e sem o `remove` o KeepAlive relança o job.
  # vazio/falhou (o command -v não resolve) → o nome como veio: o `launchctl list` lá em cima já teria dado rc 30 se ele não existisse
  lcabs=$(command -v "$LAUNCHCTL_BIN" 2>/dev/null) || lcabs=$LAUNCHCTL_BIN      # MUT:lcabs
  set -- /usr/bin/env
  while IFS= read -r kv; do [ -n "$kv" ] && set -- "$@" "$kv"; done <<EOF
$envl
EOF
  set -- "$@" /bin/bash -c "$RESUME_WRAPPER" _ "$RESUME_RC" "$RESUME_LABEL" "$lcabs" "$RFB_ROOT" \
    /bin/bash "$RFB_ROOT/scripts/job_timeout.sh" 21600 com.whatsapp.rfb-stream-resume --soft -- \
    "$RFB_PYTHON" "$RFB_ROOT/scripts/rfb_stream_refresh.py" --resume-run "$rid"
  "$LAUNCHCTL_BIN" submit -l "$RESUME_LABEL" -o "$RESUME_LOG" -e "$RESUME_LOG" -- "$@" >/dev/null 2>&1 \
    || { LAUNCH_MSG="launchctl submit falhou"; return 20; }
  # a vigia: com PID → o job vive, espero; sem PID, ou o rótulo sumiu (o wrapper o remove ao fim) → acabou, e leio o código que ele deixou.
  # vazio (rc 113: o launchd não conhece mais o rótulo) → acabou; falhou/ilegível (qualquer outro rc) → não sei se está de pé: rc 20, nunca "viva"
  while [ "$i" -lt "$WATCH_S" ]; do
    out=$("$LAUNCHCTL_BIN" list "$RESUME_LABEL" 2>/dev/null); lrc=$?
    case "$lrc" in 0|113) ;; *) LAUNCH_MSG="launchctl list $RESUME_LABEL falhou (rc $lrc) depois do submit: não sei se a retomada está de pé"; return 20 ;; esac      # MUT:watchlist
    case "$lrc:$out" in
      0:*'"PID" = '[0-9]*) sleep 1; i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  # "de pé depois da vigia" NÃO prova que passou dos portões do job (origem, checkpoints no S3 e mês rodam depois de imports e rede): o D2 para de olhar aqui; o desfecho fica em $RESUME_RC e no log
  if [ "$i" -ge "$WATCH_S" ]; then LAUNCH_MSG="retomada --resume-run $rid de pé depois de ${WATCH_S}s; o D2 não a vigia mais (o código de saída fica em $RESUME_RC, o log em $RESUME_LOG)"; return 0; fi
  "$LAUNCHCTL_BIN" remove "$RESUME_LABEL" >/dev/null 2>&1      # idempotente: o wrapper já o removeu; se ele morreu antes, o launchd o relançaria
  # vazio (o wrapper não chegou a gravar) → não sei o que houve: rc 20; falhou/ilegível (não é número) → idem. Nunca vira "terminou bem"
  code=$(cat "$RESUME_RC" 2>/dev/null)
  case "$code" in ''|*[!0-9]*) LAUNCH_MSG="a retomada terminou antes de ${WATCH_S}s e não li o código de saída ($RESUME_RC)"; return 20 ;; esac      # MUT:rcread
  case "$code" in
    0) LAUNCH_MSG="a retomada --resume-run $rid já terminou com sucesso (rc 0)"; return 0 ;;
    3) LAUNCH_MSG="o job recusou a retomada (rc 3 NÃO RODEI: janela, disco 8,25 GiB, outro processo ou mês já carregado); log: $RESUME_LOG"; return 10 ;;
    *) LAUNCH_MSG="a retomada --resume-run $rid saiu com rc $code antes de ${WATCH_S}s; log: $RESUME_LOG"; return 20 ;;
  esac
}

# ── --run / --dry-run ───────────────────────────────────────────────────────────────────────────────────────────────────────
do_run() {
  local free id adapter re pre stop_mb resume_mb window maxage how procs n pid et p lrc start crid
  load_allowlist || finish 30 "$ALLOW_ERR; não ajo"
  free=$(read_free_mb) || finish 30 "não consegui ler o livre de $VOLUME (df); não ajo"      # MUT:freefail
  local plan="" idle="" held="" row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS="$TAB" read -r id adapter re pre stop_mb resume_mb window maxage how <<EOF
$row
EOF
    procs=$(find_procs "$re" "$pre") || finish 30 "não consegui ler o ps (não sei se $id roda); não ajo"
    n=0; [ -n "$procs" ] && n=$(printf '%s\n' "$procs" | wc -l | tr -d ' ')
    if [ "$n" -gt "$MAX_MATCH" ]; then finish 30 "a regex de $id casa $n processos (> $MAX_MATCH): larga demais, não toco em nada"; fi
    if [ "$n" -eq 0 ]; then idle="${idle}${idle:+; }$id não está rodando"; continue; fi
    if [ "$free" -gt "$stop_mb" ]; then       # MUT:stopguard
      held="${held}${held:+; }$id rodando (pid $(printf '%s\n' "$procs" | cut -f1 | tr '\n' ',' | sed 's/,$//')) mas livre ${free} MB > piso de parada ${stop_mb} MB: guarda segura"
      continue
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      pid=$(printf '%s' "$p" | cut -f1); et=$(printf '%s' "$p" | cut -f4)
      start="-"; [ "$et" -ge 0 ] 2>/dev/null && start=$(( $(now) - et ))      # fixado AGORA: o 2º processo do plano não herda a demora de parar o 1º
      # o job RETOMADO leva `--resume-run <id>` na PRÓPRIA linha de comando: esse é o run_id dele, LIDO do ps (as chaves do S3 de um run retomado ficam sob o id ANTIGO e pid+hora não as achariam).
      # vazio (não é uma retomada, ou o id não tem a forma <epoch>-<pid>) → '-' e o run_id vem do S3 como antes; falhou/ilegível (o sed) → '-' também: nunca um id inventado
      crid=$(printf '%s' "$p" | cut -f5- | sed -n 's/.* --resume-run \([0-9][0-9]*-[0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' | head -n 1)
      [ -n "$crid" ] || crid="-"
      plan="${plan}${id}${TAB}${pid}${TAB}${start}${TAB}${stop_mb}${TAB}${resume_mb}${TAB}${window}${TAB}${re}${TAB}${pre}${TAB}${crid}${NL}"
    done <<EOF
$procs
EOF
  done <<EOF
$ROWS
EOF
  local summary_stopped="" summary_failed="" summary_unread="" line srp why
  if [ -z "$plan" ]; then
    local msg="$held"; [ -n "$idle" ] && msg="${msg}${msg:+; }$idle"
    finish 10 "nada a parar: $msg (livre ${free} MB)"
  fi
  if [ "$DRY" = 1 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=$(printf '%s' "$line" | cut -f1); pid=$(printf '%s' "$line" | cut -f2); stop_mb=$(printf '%s' "$line" | cut -f4)
      summary_stopped="${summary_stopped}${summary_stopped:+; }$id (pid $pid, livre ${free} MB <= piso ${stop_mb} MB)"
    done <<EOF
$plan
EOF
    finish 0 "pararia $summary_stopped (nada foi tocado)"
  fi
  acquire_lock; lrc=$?
  [ "$lrc" -eq 1 ] && finish 10 "outra instância do D2 em execução ($LOCKD): saio sem agir"
  [ "$lrc" -eq 0 ] || finish 30 "não consegui criar nem verificar a trava $LOCKD (erro de gravação, ou ps/find ilegível): não ajo"
  trim_log
  local rid rrc resume_hint=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$TAB" read -r id pid start stop_mb resume_mb window re pre crid <<EOF
$line
EOF
    # re-confere a identidade AGORA, imediatamente antes do primeiro sinal: pid que sumiu ou foi reaproveitado não recebe nada
    pid_listed "$re" "$pre" "$pid"; rrc=$?
    if [ "$rrc" -eq 2 ]; then summary_unread="${summary_unread}${summary_unread:+; }$id (pid $pid)"; log "$id pid $pid: ps ilegível na re-conferência, não toquei"; continue; fi      # MUT:recheck
    if [ "$rrc" -eq 1 ]; then log "$id pid $pid sumiu antes do sinal: nada a parar"; continue; fi
    state_append STOPPING "$id" "$pid" "$start" - "$free" "livre ${free} MB <= piso ${stop_mb} MB" || { summary_failed="${summary_failed}${summary_failed:+; }$id (pid $pid): não consegui gravar o registro em $STATE, então NÃO parei"; log "$id: registro ilegível, não parei"; continue; }      # MUT:recordfirst
    log "$id pid $pid: TERM (livre ${free} MB <= piso ${stop_mb} MB; início_epoch=$start)"
    stop_pid "$re" "$pre" "$pid"; srp=$?
    if [ "$srp" -eq 0 ]; then
      rid="-"
      if [ "$crid" != "-" ]; then
        rid=$crid      # MUT:cmdrid
        log "$id: run_id $rid lido da linha de comando do processo (--resume-run); o S3 não foi consultado"
      elif rfb_run_id "$pid" "$start"; then
        case "$RUNID_RES" in
          "ID "*) rid=${RUNID_RES#ID } ;;
          NONE) log "$id: nenhuma chave stream-run-<epoch>-$pid casa: run_id fica '-', não adivinho" ;;
          *) log "$id: mais de um run casa pid+hora ($RUNID_RES): não adivinho o run_id" ;;
        esac
      else
        log "$id: não consegui ler o S3 (o run_id fica para o --resume tentar de novo)"
      fi
      state_append STOPPED "$id" "$pid" "$start" "$rid" "$free" "morreu; livre antes ${free} MB" || log "ALERTA: $id morreu mas o registro STOPPED não gravou (o STOPPING já está lá)"      # MUT:record
      log "$id pid $pid: parado (run_id=$rid)"
      summary_stopped="${summary_stopped}${summary_stopped:+; }$id (pid $pid, livre ${free} MB <= ${stop_mb}; run_id ${rid})"
      resume_hint="${resume_hint}${resume_hint:+; }$id: retomar com --resume quando livre >= ${resume_mb} MB (janela ${window})"
    else
      if [ "$srp" -eq 1 ]; then why="não morreu depois de TERM+KILL"; else why="morte NÃO comprovada (ps ilegível, ou o pid vive sem casar mais com a allowlist)"; fi
      state_append STOP_FAILED "$id" "$pid" "$start" - "$free" "$why" || true
      log "$id pid $pid: $why"
      summary_failed="${summary_failed}${summary_failed:+; }$id (pid $pid): $why"
    fi
  done <<EOF
$plan
EOF
  if [ -n "$summary_unread" ]; then      # nada foi parado nem falhou: o ps não deixou conferir, então não agi (rc 30); se já houve ação, é falha parcial (rc 20)
    [ -n "$summary_stopped$summary_failed" ] || finish 30 "não consegui ler o ps na re-conferência de $summary_unread; não agi"
    summary_failed="${summary_failed}${summary_failed:+; }$summary_unread: ps ilegível na re-conferência, não toquei"
  fi
  if [ -n "$summary_failed" ]; then
    finish 20 "FALHOU: $summary_failed${summary_stopped:+ | parou: $summary_stopped}"
  fi
  if [ -z "$summary_stopped" ]; then finish 10 "nada a parar: o processo sumiu antes do sinal (livre ${free} MB)"; fi
  finish 0 "parou $summary_stopped; $resume_hint"
}

# ── --resume ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
pending_rows() {  # stdout: "id<TAB>pid<TAB>início<TAB>run_id<TAB>stop_epoch" dos ids cujo ÚLTIMO evento deixa a retomada pendente
  # vazio (sem arquivo = o D2 nunca parou nada) → rc 0 sem linhas; falhou/ilegível (o arquivo existe e o awk não o lê) → rc != 0, e quem chama dá rc 30
  [ -f "$STATE" ] || return 0
  awk -F'\t' '
    NF >= 7 { ev[$3] = $2; pid[$3] = $4; st[$3] = $5; rid[$3] = $6
      if ($2 == "STOPPING" || $2 == "STOPPED") ts[$3] = $1
      if ($2 == "STOPPED" && $6 != "-") rid[$3] = $6 }
    END { for (i in ev) if (ev[i] == "STOPPING" || ev[i] == "STOPPED" || ev[i] == "RESUME_REFUSED") printf "%s\t%s\t%s\t%s\t%s\n", i, pid[i], st[i], rid[i], ts[i] }' "$STATE"
}

do_resume() {
  local free pend line id pid start rid stopts row adapter re pre stop_mb resume_mb window maxage how procs age lrc code
  local started="" failed="" unread="" waiting="" abandoned="" norec="" any=0
  load_allowlist || finish 30 "$ALLOW_ERR; não ajo"
  pend=$(pending_rows) || finish 30 "não consegui ler o registro $STATE; não ajo"      # MUT:pendread
  [ -n "$pend" ] || finish 10 "nada a retomar (nenhum job parado pendente em $STATE)"
  free=$(read_free_mb) || finish 30 "não consegui ler o livre de $VOLUME (df); não ajo"
  acquire_lock; lrc=$?      # rc 0 tomei · 1 outra instância · 2 não consegui criar nem verificar (NÃO é "outra instância": mesmo contrato do --run)      # MUT:resumelock
  [ "$lrc" -eq 1 ] && finish 10 "outra instância do D2 em execução ($LOCKD): saio sem agir"
  [ "$lrc" -eq 0 ] || finish 30 "não consegui criar nem verificar a trava $LOCKD (erro de gravação, ou ps/find ilegível): não retomo"
  trim_log
  # a 1ª leitura foi SEM a trava (barata: o tick sem nada pendente nem chega a tomá-la); uma instância que terminou entre ela e a trava já pode ter retomado ou abandonado o que li.
  # Releio com a trava na mão. vazio (a outra tratou tudo) → nada a retomar; falhou/ilegível → rc 30, não ajo com uma foto velha
  pend=$(pending_rows) || finish 30 "não consegui reler o registro $STATE com a trava; não ajo"      # MUT:reread
  [ -n "$pend" ] || finish 10 "nada a retomar (outra instância tratou o pendente enquanto eu tomava a trava)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$TAB" read -r id pid start rid stopts <<EOF
$line
EOF
    any=1
    row=$(row_of "$id")
    if [ -z "$row" ]; then      # MUT:rowgone
      state_append ABANDONED "$id" "$pid" "$start" "$rid" "$free" "saiu da allowlist"
      abandoned="${abandoned}${abandoned:+; }$id (saiu da allowlist)"; continue
    fi
    IFS="$TAB" read -r id adapter re pre stop_mb resume_mb window maxage how <<EOF
$row
EOF
    case "$stopts" in ''|*[!0-9]*) unread="${unread}${unread:+; }$id: registro sem hora válida do STOP"; continue ;; esac
    age=$(( $(now) - stopts ))
    if [ "$maxage" != "-" ] && [ "$age" -gt "$maxage" ]; then      # MUT:maxage
      state_append ABANDONED "$id" "$pid" "$start" "$rid" "$free" "parado há ${age}s > ${maxage}s: o run já não vale"
      abandoned="${abandoned}${abandoned:+; }$id (parado há ${age}s > ${maxage}s: o próximo tick recomeça do zero)"; continue
    fi
    procs=$(find_procs "$re" "$pre") || { unread="${unread}${unread:+; }$id: não consegui ler o ps"; continue; }
    if [ -n "$procs" ]; then      # MUT:running
      state_append ABANDONED "$id" "$pid" "$start" "$rid" "$free" "já há processo do job rodando"
      abandoned="${abandoned}${abandoned:+; }$id (já há processo rodando: pid $(printf '%s\n' "$procs" | head -n 1 | cut -f1))"; continue
    fi
    if [ "$free" -lt "$resume_mb" ]; then      # MUT:hyst
      waiting="${waiting}${waiting:+; }$id (livre ${free} MB < ${resume_mb} MB)"; continue
    fi
    if ! in_window "$window"; then      # MUT:window
      waiting="${waiting}${waiting:+; }$id (fora da janela $window)"; continue
    fi
    if [ "$rid" = "-" ]; then
      if rfb_run_id "$pid" "$start"; then
        case "$RUNID_RES" in "ID "*) rid=${RUNID_RES#ID } ;; esac
      else
        unread="${unread}${unread:+; }$id: não consegui ler o S3 para achar o run_id (não adivinho)"; continue      # MUT:noguess
      fi
    fi
    case "$rid" in '-'|'') rid="" ;; esac
    if [ -z "$rid" ]; then
      state_append ABANDONED "$id" "$pid" "$start" - "$free" "sem run_id comprovado: nada a retomar"
      abandoned="${abandoned}${abandoned:+; }$id (sem checkpoint no S3 casando pid $pid: o tick da noite recomeça do zero)"; continue
    fi
    if ! printf '%s' "$rid" | grep -Eq '^[0-9]+-[0-9]+$'; then      # MUT:ridvalid
      state_append ABANDONED "$id" "$pid" "$start" "$rid" "$free" "run_id com forma inválida"
      abandoned="${abandoned}${abandoned:+; }$id (run_id com forma inválida no registro: recuso)"; continue
    fi
    log "$id: retomando --resume-run $rid (livre ${free} MB >= ${resume_mb})"
    rfb_launch "$rid"; code=$?
    case "$code" in
      0)  state_append RESUME_STARTED "$id" "$pid" "$start" "$rid" "$free" "$LAUNCH_MSG" || { norec="${norec}${norec:+; }$id"; log "ALERTA: $id retomou (--resume-run $rid) mas o registro RESUME_STARTED não gravou: o próximo --resume pode lançar de novo"; }      # MUT:startrecord
          started="${started}${started:+; }$id --resume-run $rid: $LAUNCH_MSG" ;;
      10) state_append RESUME_REFUSED "$id" "$pid" "$start" "$rid" "$free" "$LAUNCH_MSG"
          waiting="${waiting}${waiting:+; }$id: $LAUNCH_MSG" ;;
      30) unread="${unread}${unread:+; }$id: $LAUNCH_MSG" ;;
      *)  state_append RESUME_FAILED "$id" "$pid" "$start" "$rid" "$free" "$LAUNCH_MSG"
          failed="${failed}${failed:+; }$id --resume-run $rid: $LAUNCH_MSG (retome à mão com o run_id)" ;;
    esac
  done <<EOF
$pend
EOF
  [ "$any" = 1 ] || finish 10 "nada a retomar"
  if [ -n "$failed" ]; then finish 20 "FALHOU: $failed${started:+ | retomou: $started}${unread:+ | não li: $unread}"; fi
  if [ -n "$started" ]; then finish 0 "retomou $started${norec:+ | ALERTA: o job subiu mas o registro RESUME_STARTED NÃO gravou ($norec): um novo --resume pode lançar de novo se ele cair}${waiting:+ | adiado: $waiting}${abandoned:+ | abandonado: $abandoned}${unread:+ | não li: $unread}"; fi
  if [ -n "$unread" ]; then finish 30 "não consegui ler o estado e não retomei: $unread"; fi
  finish 10 "nada retomado: ${waiting}${waiting:+${abandoned:+ | }}${abandoned:+abandonado: $abandoned}"
}

usage() { MODE="${MODE:-uso}"; DRY=1; finish 2 "uso: $0 --run | --dry-run | --resume"; }      # DRY=1: uso errado não escreve no log de produção
case "${1:-}" in
  --run)     MODE="--run" ;;
  --dry-run) MODE="--dry-run"; DRY=1 ;;
  --resume)  MODE="--resume" ;;
  *)         usage ;;
esac
[ "$#" -eq 1 ] || usage
if [ "$MODE" = "--resume" ]; then do_resume; else do_run; fi
