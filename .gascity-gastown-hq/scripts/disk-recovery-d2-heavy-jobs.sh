#!/bin/bash
# disk-recovery-d2-heavy-jobs.sh — degrau D2 da escada de recuperação de disco do mini (ga-1p1i5jr.2, missão ga-1p1i5jr).
#
# ## Contents
#   Para que serve · Uso · Contrato (saída e códigos) · A allowlist · O que o rfb ensina · O registro do que foi parado · Como retomar (à mão nesta fatia) · Guardas · Variáveis · Teste
#
# PARA QUE SERVE. A escada (ga-1p1i5jr.1, scripts/disk-recovery-ladder.sh) chama este degrau quando o livre do volume de dados ficou <= 5 GB por 15 min: D1 (limpar
# arquivo) já tentou. Aqui se PARA, e só se para, jobs pesados e reiniciáveis que estão na ALLOWLIST (scripts/disk-recovery-d2-allowlist.tsv). Memória pesada vira
# swap e o swap sai do MESMO disco (01/11: disco 2 GB, swap 4,8 GB de 6 GB) — soltar a pegada de um lote de horas libera o disco sem apagar nada de ninguém.
# Decisão do Athos para a escada (citável): AskUserQuestion na sessão do Mayor, 01/11/2026 ~11:00 BRT, "A qualquer hora, com guardas (Recomendado)".
#
# USO
#   disk-recovery-d2-heavy-jobs.sh --dry-run   só diz o que faria. Não toma trava, não grava estado nem log, não lê o S3.
#   disk-recovery-d2-heavy-jobs.sh --run       real: para o que a allowlist manda parar e anota o que parou.
#
# CONTRATO (o do Mayor + o do orquestrador dog-2). stdout: UMA linha, sempre ("D2 --run: ..."). Códigos de saída:
#   0   agiu e terminou     (parou ao menos um e todos morreram)
#   10  nada a fazer, ou uma guarda adiou (nada rodando · rodando mas o livre está acima do piso de parada do job · outra instância em execução)
#   20  falhou              (não conseguiu gravar o registro, o processo não morreu, erro interno)
#   30  não consegui ler o estado e por isso NÃO agi (df, ps ou allowlist ilegíveis; não conseguiu criar a trava; regex larga demais)
#   --dry-run devolve os mesmos códigos como previsão (0 = agiria). Quem avisa o Athos (notify/mail em 0/20) é o orquestrador: este degrau só escreve o próprio log.
#
# A ALLOWLIST. Casa por REGEX contra a linha de comando do processo E a do PAI (o job de verdade tem o pai do launchd), nunca por tamanho de memória. O arquivo é
# a documentação viva: por linha, o piso de PARADA, o piso de RETOMADA, a janela e o COMO. Nele também estão, comentados, os candidatos REJEITADOS e por quê.
#
# O QUE O RFB ENSINA (a pergunta do bead: retoma do ponto ou do zero?). Por TABELA: a que terminou e foi verificada tem checkpoint no S3 e é reaproveitada; a que estava
# em andamento recomeça do ZERO (horas). Por isso o piso de parada do rfb é 3 GB (não os 5 GB em que o D2 é chamado): acima disso o D2 devolve 10 e deixa o job
# terminar a tabela. O tick das 00:15 seguinte começa um run NOVO — a retomada tem de vir antes dele (o --resume é a fatia 2/2, bead ga-1p1i5jr.2.1).
#
# O REGISTRO DO QUE FOI PARADO. $D2_STATE (padrão $CITY/.gc/disk-recovery-d2.state), TSV de eventos, só acrescenta:
#   epoch  EVENTO  id  pid  início_epoch  run_id  livre_MB  detalhe          (campo vazio = `-`)
#   STOPPING (gravado ANTES do kill) → STOPPED (morreu; carrega o run_id lido do S3) | STOP_FAILED
#
# COMO RETOMAR (à mão, nesta fatia; o --resume automático é a fatia 2/2, bead ga-1p1i5jr.2.1). Com o livre >= resume_above_mb do job e dentro da janela dele, rodar
# `rfb_stream_refresh.py --resume-run <run_id>`: o run_id está na linha FIM do --run e no registro. Se for `-`, o D2 não o leu (S3 fora do ar, nenhuma chave casando ou
# mais de uma): então NÃO se adivinha; ver as chaves stream-run-* em RFB_META_URI. Sem retomar, o tick das 00:15 recomeça do zero.
#
# GUARDAS. (1) só mexe em processo da allowlist, do MEU usuário, com o pai certo, e re-confere a identidade imediatamente antes de cada sinal (pid reaproveitado nunca
# recebe KILL); (2) "não consegui medir" nunca vira "disco baixo" nem "disco bom": é rc 30 e não age; (3) o registro é gravado ANTES do kill — sem registro, não para;
# (4) TERM primeiro (SIGINT não serve: sob launchd o filho de `&` o herda ignorado), KILL só depois da graça e só se o processo ainda for o job; morte comprovada
# por ps, não suposta; (5) regex que casa mais de $D2_MAX_MATCH processos = regex larga demais: rc 30, nada é tocado; (6) instância única por trava (mkdir).
#
# VARIÁVEIS (todas opcionais; as de TESTE estão marcadas). D2_CITY D2_ALLOWLIST D2_STATE D2_LOG D2_LOCK D2_VOLUME D2_TERM_GRACE_S D2_KILL_WAIT_S D2_MAX_MATCH D2_S3_TIMEOUT_S
# D2_RFB_META_URI · binários: D2_PS_BIN D2_DF_BIN D2_AWS_BIN · TESTE: D2_FREE_MB D2_NOW.
# TESTE: bash scripts/disk-recovery-d2-heavy-jobs.selftest.sh   (hermético: processos de brinquedo, ps/df/aws simulados; nada real é parado; bateria de mutantes inclusa).
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
DF_BIN="${D2_DF_BIN:-df}"
AWS_BIN="${D2_AWS_BIN:-aws}"
RFB_META_URI="${D2_RFB_META_URI:-s3://urblink-motherduck-backups/real_estate/rfb/_meta/}"
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

read_free_mb() {  # stdout: MB livres no volume de dados; rc 1 = não consegui ler (nunca imprime 0 no lugar do erro)
  local v="${D2_FREE_MB:-}" out
  if [ -n "$v" ]; then
    case "$v" in *[!0-9]*) return 1 ;; esac
    printf '%s' "$v"; return 0
  fi
  out=$("$DF_BIN" -Pk "$VOLUME" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk 'NR==2 && $4 ~ /^[0-9]+$/ { printf "%d", $4/1024; ok=1 } END { exit ok ? 0 : 1 }'
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

stop_pid() {  # $1=match $2=parent $3=pid → rc 0 = morreu (comprovado), 1 = não morreu / não consegui provar
  local re=$1 pre=$2 pid=$3 i=0 max r
  kill -TERM "$pid" 2>/dev/null
  max=$((TERM_GRACE_S * 5))
  while [ "$i" -lt "$max" ]; do
    pid_listed "$re" "$pre" "$pid"; r=$?
    [ "$r" -eq 1 ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  pid_listed "$re" "$pre" "$pid"; r=$?
  [ "$r" -eq 1 ] && return 0
  [ "$r" -eq 0 ] || return 1                      # não consigo ler o ps: não mando KILL às cegas e não digo que morreu
  log "pid $pid sobreviveu à graça de ${TERM_GRACE_S}s depois do TERM: KILL"
  kill -KILL "$pid" 2>/dev/null                   # MUT:killescalate
  i=0; max=$((KILL_WAIT_S * 5))
  while [ "$i" -lt "$max" ]; do
    pid_listed "$re" "$pre" "$pid"; r=$?
    [ "$r" -eq 1 ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

acquire_lock() {  # rc 0 = tomei · 1 = outra instância viva · 2 = não consegui criar a trava (erro de gravação: NÃO é "outra instância")
  mkdir -p "$(dirname "$LOCKD")" 2>/dev/null || return 2
  if mkdir "$LOCKD" 2>/dev/null; then printf '%s' "$$" >"$LOCKD/pid"; LOCK_HELD=1; return 0; fi
  local p; p=$(cat "$LOCKD/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 1; fi      # pid ilegível = trava abandonada (entre o mkdir e o pid do dono passam microssegundos)
  rm -rf "$LOCKD" 2>/dev/null
  if mkdir "$LOCKD" 2>/dev/null; then printf '%s' "$$" >"$LOCKD/pid"; LOCK_HELD=1; return 0; fi
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

# ── --run / --dry-run ───────────────────────────────────────────────────────────────────────────────────────────────────────
do_run() {
  local free id adapter re pre stop_mb resume_mb window maxage how procs n pid et p lrc
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
      plan="${plan}${id}${TAB}${pid}${TAB}${et}${TAB}${stop_mb}${TAB}${resume_mb}${TAB}${window}${TAB}${re}${TAB}${pre}${NL}"
    done <<EOF
$procs
EOF
  done <<EOF
$ROWS
EOF
  local summary_stopped="" summary_failed="" line
  if [ -z "$plan" ]; then
    local why="$held"; [ -n "$idle" ] && why="${why}${why:+; }$idle"
    finish 10 "nada a parar: $why (livre ${free} MB)"
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
  [ "$lrc" -eq 0 ] || finish 30 "não consegui criar a trava $LOCKD (erro de gravação): não ajo"
  trim_log
  local start rid rrc resume_hint=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$TAB" read -r id pid et stop_mb resume_mb window re pre <<EOF
$line
EOF
    start="-"; [ "$et" -ge 0 ] 2>/dev/null && start=$(( $(now) - et ))
    # re-confere a identidade AGORA, imediatamente antes do primeiro sinal: pid que sumiu ou foi reaproveitado não recebe nada
    pid_listed "$re" "$pre" "$pid"; rrc=$?
    if [ "$rrc" -eq 2 ]; then summary_failed="${summary_failed}${summary_failed:+; }$id (pid $pid): ps ilegível na re-conferência, não toquei"; continue; fi
    if [ "$rrc" -eq 1 ]; then log "$id pid $pid sumiu antes do sinal: nada a parar"; continue; fi
    state_append STOPPING "$id" "$pid" "$start" - "$free" "livre ${free} MB <= piso ${stop_mb} MB" || { summary_failed="${summary_failed}${summary_failed:+; }$id (pid $pid): não consegui gravar o registro em $STATE, então NÃO parei"; log "$id: registro ilegível, não parei"; continue; }      # MUT:recordfirst
    log "$id pid $pid: TERM (livre ${free} MB <= piso ${stop_mb} MB; início_epoch=$start)"
    if stop_pid "$re" "$pre" "$pid"; then
      rid="-"
      if rfb_run_id "$pid" "$start"; then
        case "$RUNID_RES" in
          "ID "*) rid=${RUNID_RES#ID } ;;
          NONE) log "$id: nenhum checkpoint no S3 para o pid $pid (nada a retomar além do zero)" ;;
          *) log "$id: mais de um run casa pid+hora ($RUNID_RES): não adivinho o run_id" ;;
        esac
      else
        log "$id: não consegui ler o S3 (run_id fica '-': não adivinho; ver as chaves stream-run-* em $RFB_META_URI)"
      fi
      state_append STOPPED "$id" "$pid" "$start" "$rid" "$free" "morreu; livre antes ${free} MB" || log "ALERTA: $id morreu mas o registro STOPPED não gravou (o STOPPING já está lá)"      # MUT:record
      log "$id pid $pid: parado (run_id=$rid)"
      summary_stopped="${summary_stopped}${summary_stopped:+; }$id (pid $pid, livre ${free} MB <= ${stop_mb}; run_id ${rid})"
      if [ "$rid" = "-" ]; then
        resume_hint="${resume_hint}${resume_hint:+; }$id: run_id NÃO lido (ver stream-run-* em $RFB_META_URI)"
      else
        resume_hint="${resume_hint}${resume_hint:+; }$id: retomar à mão com rfb_stream_refresh.py --resume-run $rid quando livre >= ${resume_mb} MB (janela ${window})"
      fi
    else
      state_append STOP_FAILED "$id" "$pid" "$start" - "$free" "não morreu depois de TERM+KILL" || true
      log "$id pid $pid: NÃO morreu depois de TERM e KILL"
      summary_failed="${summary_failed}${summary_failed:+; }$id (pid $pid) não morreu depois de TERM+KILL"
    fi
  done <<EOF
$plan
EOF
  if [ -n "$summary_failed" ]; then
    finish 20 "FALHOU: $summary_failed${summary_stopped:+ | parou: $summary_stopped}"
  fi
  if [ -z "$summary_stopped" ]; then finish 10 "nada a parar: o processo sumiu antes do sinal (livre ${free} MB)"; fi
  finish 0 "parou $summary_stopped; $resume_hint"
}

usage() { MODE="${MODE:-uso}"; finish 2 "uso: $0 --run | --dry-run"; }
case "${1:-}" in
  --run)     MODE="--run" ;;
  --dry-run) MODE="--dry-run"; DRY=1 ;;
  *)         usage ;;
esac
[ "$#" -eq 1 ] || usage
do_run
