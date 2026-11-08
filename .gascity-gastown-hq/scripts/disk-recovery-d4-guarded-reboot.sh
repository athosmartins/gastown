#!/bin/bash
# disk-recovery-d4-guarded-reboot.sh — D4 da escada de disco: reinício GUARDADO do mini (ga-1p1i5jr.4)
#
# ## Contents
#   Decisão · Contrato · Ordem · Guardas · Reinício · Pedido pendente · Costuras de teste
#
# DECISÃO (Athos, 01/11/2026 ~11:00 BRT, AskUserQuestion na sessão do Mayor, citada na ga-1p1i5jr): "A qualquer hora, com guardas" — o mini
#   reinicia sozinho com o disco < 3 GB por 60 min (ou < 1,5 GB a qualquer momento), só sem ligação em curso nem envio em voo, e AVISA. Os guardas
#   de disco que já existiam só limpam ARQUIVO; em 01/11 a causa foi RAM virando swap (2-4 GB livres por 5 h). O reinício devolve o swap.
#
# CONTRATO (Mayor + comentário do orquestrador em ga-1p1i5jr.4): `--run` age; `--dry-run` roda TODAS as leituras e diz o que faria (sem estado, sem
#   aviso, sem reinício). stdout = UMA linha; o resto vai pro log. Saída 0 = agiu (--run: pediu o reinício, e o desligamento costuma matar o
#   processo antes de imprimir; --dry-run: "reiniciaria") · 10 = nada a fazer ou uma guarda adiou · 20 = falhou · 30 = não consegui ler (NÃO age) · 2 = uso.
#   O TEMPO do limiar é do orquestrador (disk-recovery-ladder.sh, .1), que também faz notify+mail em rc 0/20; aqui fica só o cooldown PRÓPRIO.
#
# ORDEM (3 estados em TODA leitura — leu e é / leu e não é / não consegui ler —; "não consegui ler" cai SEMPRE do lado inerte: não reinicia):
#   1 interruptor `touch .gc/disk-recovery.off` (o do orquestrador)  2 trava de instância única + estado  3 disco ≥ 3 GB agora = recuperou (df do
#   volume de dados, nunca `df /`)  4 cooldown de 6 h, teto de 2 por 24 h, mini no ar há < 2 h por qualquer causa (com o disco ainda baixo depois de
#   um reinício nosso: NÃO reinicia de novo e escala UMA vez por reinício)  5 espera (10 min depois que uma guarda adiou, 30 min depois de um pedido que não derrubou o mini)  6 pré-checagem: FileVault
#   desligado + autologin do usuário do console + postcheck pós-boot carregado (senão o mini volta parado na tela de senha)  7 guardas  8 `--run`:
#   aviso -p 5 ANTES (entrega CONFIRMADA; se o push não foi, mail ao Mayor; os dois falharam = rc 30 e NÃO reinicia) → 60 s de carência (o interruptor ainda aborta) → RELÊ disco,
#   pré-checagem e guardas (o veredito de minutos atrás não vale; cancelou depois do aviso = espera de 10 min, senão a rodada seguinte reenvia o aviso) → grava e CONFERE
#   a marca do reinício → só então pede o reinício; pedido com erro desfaz a marca e sai 20; mini ainda no ar 180 s depois = marca PENDENTE (abaixo) e sai 20.
#
# PEDIDO PENDENTE (ga-1p1i5jr.4.3): "ainda no ar 180 s depois" NÃO é "não vai cair" (um app segurando o logout termina o desligamento depois). A marca fica na lista e o estado guarda
#   pending_mark/pending_boot; a rodada SEGUINTE (resolve_pending, antes do cooldown) confere o kern.boottime: mudou = o mini reiniciou, a marca vale (cooldown, teto e escalada); igual = não
#   reiniciou, e depois de marca+30 min solta a marca e segue o fluxo normal (antes disso espera, sem escalar). Tolerância de BOOT_TOL_S para ajuste curto do relógio.
#
# GUARDAS (todas avaliadas; qualquer uma bloqueia = 10 + espera + aviso; nenhuma bloqueia mas alguma ilegível = 30): ligação em curso
#   (disk-recovery-d4-calls-in-flight.py: o live_calls() do pix e o do voicebot devolvem [] em QUALQUER erro, então "não consegui ler" e "não há
#   ligação" seriam o mesmo valor) · envio em voo (whatsapp_automation central_sender_restart_safe.py: 0/1/2) · manutenção do Dolt e rodada do scraper:
#   o MESMO código do reinício noturno, EXTRAÍDO do nightly-reboot.sh pelas sentinelas (sentinela ausente ou duplicada = "não sei", nunca "livre").
#   Não usa o `nightly-reboot.sh --check-guards` inteiro: o guard3 (beads hq em andamento) bloquearia para sempre (sempre há agente trabalhando; o
#   próprio noturno em modo dreno decide só pelas guardas de segurança) e ele não tem timeout — Dolt doente é o cenário de disco cheio.
#
# REINÍCIO. Sem sudo (não há sudoers.d; `Bash(sudo:*)` é "ask"): o MESMO AppleEvent dos reinícios manuais do Mayor (osascript → loginwindow
#   `aevtrrst`), com LANG=en_US.UTF-8 explícito (sob launchd não há LANG e o «» precisa chegar como UTF-8). NÃO verificado: se a Automação do macOS
#   libera esse envio na cadeia do launchd do orquestrador (de uma sessão de agente a sonda de permissão dá -1744 e o reinício do Mayor funciona
#   mesmo assim, então ela não serve de preditor). Falha vira rc 20 e desfaz a marca; a prova real é o canário do D5.
#
# COSTURAS (DR4_*; o selftest NUNCA reinicia de verdade): DR4_REBOOT_CMD · DR4_NO_REAL_REBOOT=1 (recusa o comando de verdade) · DR4_FREE_MB_OVERRIDE ·
#   DR4_NOW · DR4_BOOT_EPOCH · DR4_CONSOLE_USER · DR4_*_BIN · DR4_CALLS_PY · DR4_SENDER_SAFE_PY · DR4_NIGHTLY · DR4_STATE/LOG/LOCKD · limites numéricos
#   (número ilegível cai no padrão e é dito no log). Compartilhados com o orquestrador DE PROPÓSITO: DR_OFF_FILE, DR_NOTIFY_BIN, DR_GC_BIN. Bash 3.2.

set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
CITY="${DR_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
STATE="${DR4_STATE:-$GCDIR/disk-recovery-d4.state}"
LOG="${DR4_LOG:-$GCDIR/logs/disk-recovery-d4.log}"
OFF="${DR_OFF_FILE:-$GCDIR/disk-recovery.off}"
LOCKD="${DR4_LOCKD:-$STATE.lock.d}"
NOTIFY="${DR_NOTIFY_BIN:-$HOME/.local/bin/notify}"
GCBIN="${DR_GC_BIN:-${GC_BIN:-gc}}"
VOLUME="${DR4_VOLUME:-/System/Volumes/Data}"
PY="${DR4_PYTHON:-/usr/bin/python3}"
CALLS_PY="${DR4_CALLS_PY:-$D/disk-recovery-d4-calls-in-flight.py}"
SENDER_PY="${DR4_SENDER_SAFE_PY:-/Users/athos/gt/whatsapp_automation/scripts/central_sender_restart_safe.py}"
NIGHTLY="${DR4_NIGHTLY:-$CITY/scripts/nightly-reboot.sh}"
PGREP="${DR4_PGREP_BIN:-/usr/bin/pgrep}"
FDESETUP="${DR4_FDESETUP_BIN:-/usr/bin/fdesetup}"
DEFAULTS="${DR4_DEFAULTS_BIN:-/usr/bin/defaults}"
LAUNCHCTL="${DR4_LAUNCHCTL_BIN:-/bin/launchctl}"
SYSCTL="${DR4_SYSCTL_BIN:-/usr/sbin/sysctl}"
STATBIN="${DR4_STAT_BIN:-/usr/bin/stat}"
DFBIN="${DR4_DF_BIN:-/bin/df}"
POSTCHECK_LABEL="${DR4_POSTCHECK_LABEL:-com.gascity.nightly-reboot-postcheck}"
OSASCRIPT="${DR4_OSASCRIPT_BIN:-/usr/bin/osascript}"

DRY=0
CFG_WARN=""
LOCK_HELD=0
EMITTED=0
RB_OUT=""

cfg() {  # $1=nome $2=padrão → define $1 com DR4_$1 (só dígitos, até 9). Vazio → padrão; lixo → padrão E registra em CFG_WARN (limite ilegível não vira "sem limite")
  local v
  eval "v=\${DR4_$1:-}"
  case "$v" in
    '') v=$2 ;;
    *[!0-9]*) CFG_WARN="$CFG_WARN DR4_$1='$v'->$2"; v=$2 ;;
    *) [ "${#v}" -le 9 ] || { CFG_WARN="$CFG_WARN DR4_$1='$v'->$2"; v=$2; } ;;
  esac
  eval "$1=\$v"
}
cfg MB 3072            # reinicia só com o disco abaixo disto (o limiar do D4 na missão: < 3 GB)
cfg HARD_MB 1536       # abaixo disto o motivo é "crítico" (só muda o texto do aviso; o TEMPO do limiar é do orquestrador)
cfg COOLDOWN_S 21600   # 1 reinício automático a cada 6 h
cfg DAY_CAP 2          # e no máximo 2 por 24 h
cfg DAY_WINDOW_S 86400
cfg MIN_UPTIME_S 7200  # mini no ar há menos disto (por QUALQUER causa) = um reinício agora não ajudaria e abre laço
cfg DEFER_S 600        # depois que uma guarda adiou: não tenta de novo por 10 min
cfg DEFER_NOTIFY_S 3600  # aviso de adiamento/"cego" no máximo 1 por hora
cfg ATTEMPT_GAP_S 1800 # depois de um pedido que NÃO reiniciou: a espera é de 30 min (a mesma espera do hold)
cfg GRACE_S 60         # carência entre o aviso e o reinício (o interruptor aborta)
cfg WAIT_S 180         # depois do pedido aceito: espera isto o mini cair; vivo depois = AINDA não caiu (pode estar só lento: a marca fica PENDENTE, ver resolve_pending)
cfg BOOT_TOL_S 300     # kern.boottime que difere do gravado por até isto = mesmo boot (um reinício de verdade o move por >= MIN_UPTIME_S; um ajuste curto do relógio não é reinício)
cfg REBOOT_TIMEOUT_S 90
cfg CALL_MAX_AGE_MIN 240
cfg GUARD_TIMEOUT_S 60
cfg NOTIFY_TIMEOUT_S 20
cfg MAIL_TIMEOUT_S 30

now() { case "${DR4_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$DR4_NOW" ;; esac; }
hhmm() { date -r "$1" '+%H:%M' 2>/dev/null || printf '%s' "$1"; }

log() {
  local p=""; [ "$DRY" = 1 ] && p="[dry-run] "
  printf '[%s] %s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$p" "$*" >> "$LOG" 2>/dev/null
  return 0
}

release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCKD/pid" 2>/dev/null; rmdir "$LOCKD" 2>/dev/null; LOCK_HELD=0; fi
  return 0
}
trap release_lock EXIT
trap 'exit 143' TERM   # o desligamento manda TERM: sai por aqui e o EXIT trap solta a trava (sem imprimir linha: o mini está caindo)
trap 'exit 130' INT
trap 'exit 129' HUP

emit() {  # $1=rc; resto=texto. A ÚNICA linha do stdout; sai. Nunca chamar dentro de $(...)
  local rc=$1; shift
  if [ "$EMITTED" = 0 ]; then
    EMITTED=1
    local line="D4"
    [ "$DRY" = 1 ] && line="D4 (dry-run)"
    line="$line: $*"
    line=$(printf '%s' "$line" | tr '\n\r' '  ')
    printf '%s\n' "$line"
    log "resultado rc=$rc — $line"
  fi
  exit "$rc"
}

# ── executar com prazo (macOS não tem timeout(1)) ───────────────────────────────────────────────────────────────────────────────
run_bounded() {  # $1=segundos; resto=comando. Saída (stdout+stderr) em $RB_OUT. rc do comando; 124 = estourou o prazo (TERM, depois KILL); 125 = sem arquivo temporário
  local secs=$1 pid ticks=0 limit
  shift
  RB_OUT=$(mktemp "${TMPDIR:-/tmp}/disk-recovery-d4.XXXXXX" 2>/dev/null) || { RB_OUT=""; return 125; }
  limit=$((secs * 5))
  "$@" > "$RB_OUT" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$pid"
}
out_line() {  # primeira linha de $RB_OUT, só imprimíveis, até 300. Sem saída = "(sem saída)": a falta de linha não vira sucesso nem falha por si
  local l=""
  [ -n "$RB_OUT" ] && [ -r "$RB_OUT" ] && l=$(sed -n 1p "$RB_OUT" 2>/dev/null | LC_ALL=C tr -cd '[:print:]' | cut -c1-300)
  printf '%s' "${l:-(sem saída)}"
}
out_raw() {  # primeira linha de $RB_OUT SEM filtrar (preserva o TAB do estado<TAB>detalhe do calls-in-flight); vazio = ""
  [ -n "$RB_OUT" ] && [ -r "$RB_OUT" ] && sed -n 1p "$RB_OUT" 2>/dev/null | cut -c1-400
  return 0
}
rb_clean() { [ -n "$RB_OUT" ] && rm -f "$RB_OUT" 2>/dev/null; RB_OUT=""; return 0; }

send_notify() {  # $1=prioridade $2=título $3=mensagem. rc 0 = ENTREGUE; rc 1 = NÃO confirmado (rc≠0, prazo estourado ou sem arquivo temporário: quem depende da entrega NÃO a presume). dry-run só registra e devolve 0
  if [ "$DRY" = 1 ]; then log "(notify -p $1 '$2' — não enviado em dry-run) $3"; return 0; fi
  local rc
  # NOTIFY_STRICT_EXIT=1: sem ele o notify sai 0 também em dedup/digest/segurado-até-as-7h (nada chegou); com ele, nos caminhos de política, rc 0 = push com 2xx e o resto é rc≠0 (ga-trv57j); só NOTIFY_DISABLE/PYTEST_CURRENT_TEST/preview ainda saem 0 sem enviar (ambiente de teste, não o do launchd)
  # O notify decide push-vs-resumo-horário pela REDAÇÃO, não pelo -p (ga-ff6t9): prioridade >= 4 = "tem de chegar no celular" → NOTIFY_FORCE_PUSH=1
  if [ "$1" -ge 4 ]; then
    NOTIFY_STRICT_EXIT=1 NOTIFY_FORCE_PUSH=1 run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
  else
    NOTIFY_STRICT_EXIT=1 run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
  fi
  [ "$rc" -eq 0 ] || log "WARN: notify NÃO confirmado rc=$rc ($(out_line))"
  rb_clean
  [ "$rc" -eq 0 ]
}
send_mail() {  # $1=assunto $2=corpo. rc 0 = entregue; rc 1 = não confirmado (mesmo contrato do send_notify)
  if [ "$DRY" = 1 ]; then log "(mail ao Mayor '$1' — não enviado em dry-run)"; return 0; fi
  # SEM --from (ga-hp9pwtr): o engine só aceita `--from` de human, controller ou de uma sessão que exista, e "disk-recovery-d4" não é nenhuma. Com ele este mail (o 2º canal do aviso) falhava SEMPRE
  # ("invalid sender … session not found") e, com o push no teto global (notify rc 12), o D4 saía rc 30 e nunca reiniciava. Sem --from o remetente é a identidade padrão do engine (human sob o launchd,
  # a própria sessão numa sessão): o mesmo caminho do orquestrador. Também não troque por `--from human|controller`: no fonte do engine (upstream, mailSenderAuthorizedCached; não medido na versão do mini)
  # uma sessão só pode assumir a identidade DELA, então o D4 rodado à mão de uma sessão falharia de novo. Sem remetente próprio, a origem vai no corpo.
  run_bounded "$MAIL_TIMEOUT_S" "$GCBIN" mail send mayor -s "$1" -m "$2"$'\n\n'"[origem: disk-recovery-d4-guarded-reboot.sh — D4 da escada de disco]"
  local rc=$?
  [ "$rc" -eq 0 ] || log "WARN: gc mail send mayor NÃO confirmado rc=$rc ($(out_line))"
  rb_clean
  [ "$rc" -eq 0 ]
}

# ── estado (chave=valor, escrito inteiro e trocado com mv) ─────────────────────────────────────────────────────────────────────
S_REBOOTS=""; S_DEFER_UNTIL=0; S_DEFER_NOTIFY=0; S_ESC_FOR=0; S_PEND_MARK=0; S_PEND_BOOT=0; STATE_ERR=""
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "${#1}" -le 12 ] ;; esac; }
valid_list() {  # lista de números separados por vírgula (vazia vale); elemento vazio ou com > 12 dígitos não vale (estouraria a aritmética sem avisar)
  local e IFS=,
  case "$1" in '') return 0 ;; *[!0-9,]*|,*|*,|*,,*) return 1 ;; esac
  for e in $1; do isnum "$e" || return 1; done
  return 0
}

state_load() {  # rc 0 = lido (arquivo AUSENTE = estado vazio = primeira vez); rc 1 = existe e não consigo ler/entender → STATE_ERR (NÃO age)
  S_REBOOTS=""; S_DEFER_UNTIL=0; S_DEFER_NOTIFY=0; S_ESC_FOR=0; S_PEND_MARK=0; S_PEND_BOOT=0; STATE_ERR=""
  [ -e "$STATE" ] || return 0
  [ -r "$STATE" ] && [ -f "$STATE" ] || { STATE_ERR="$STATE existe mas não é um arquivo legível"; return 1; }
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      '') ;;
      v) [ "$v" = 1 ] || { STATE_ERR="versão de estado desconhecida (v=$v)"; return 1; } ;;
      reboots) valid_list "$v" || { STATE_ERR="reboots não é uma lista de números ('$v')"; return 1; }; S_REBOOTS=$v ;;
      defer_until)     isnum "$v" || { STATE_ERR="defer_until='$v'"; return 1; };     S_DEFER_UNTIL=$v ;;
      defer_notify_ts) isnum "$v" || { STATE_ERR="defer_notify_ts='$v'"; return 1; }; S_DEFER_NOTIFY=$v ;;
      esc_for)         isnum "$v" || { STATE_ERR="esc_for='$v'"; return 1; };         S_ESC_FOR=$v ;;
      # chave ausente → 0 = nenhum pedido pendente (estado de antes da ga-1p1i5jr.4.3 lê assim); valor vazio/não numérico → rc 1 e NÃO age (nunca vira "sem pendência")
      pending_mark)    isnum "$v" || { STATE_ERR="pending_mark='$v'"; return 1; };    S_PEND_MARK=$v ;;
      pending_boot)    isnum "$v" || { STATE_ERR="pending_boot='$v'"; return 1; };    S_PEND_BOOT=$v ;;
      *) ;;  # chave que não conheço (versão futura do mesmo v=1): ignora
    esac
  done < "$STATE"
  # pendência sem o boot de referência não dá para conferir (nem "mudou" nem "igual"): ilegível, NÃO age — soltar a marca ou mantê-la às cegas seria chute
  if [ "$S_PEND_MARK" -gt 0 ] && [ "$S_PEND_BOOT" -le 0 ]; then STATE_ERR="pending_mark=$S_PEND_MARK sem pending_boot (não há com o que conferir o kern.boottime)"; return 1; fi
  return 0
}
state_save() {  # rc 0 = gravou; rc 1 = não gravou (o chamador decide; antes do reinício, NÃO gravar = NÃO reiniciar)
  local tmp="$STATE.tmp.$$"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  if printf 'v=1\nreboots=%s\ndefer_until=%s\ndefer_notify_ts=%s\nesc_for=%s\npending_mark=%s\npending_boot=%s\n' \
       "$S_REBOOTS" "$S_DEFER_UNTIL" "$S_DEFER_NOTIFY" "$S_ESC_FOR" "$S_PEND_MARK" "$S_PEND_BOOT" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
prune_reboots() {  # $1=agora → só marcas dos últimos 7 dias (o resto não decide nada). Marca no FUTURO (relógio voltou) fica: conta contra o teto
  local e out="" IFS=,
  for e in $S_REBOOTS; do
    [ -n "$e" ] || continue
    [ $(( $1 - e )) -le 604800 ] && out="${out:+$out,}$e"
  done
  S_REBOOTS=$out
}
last_reboot() {  # imprime a marca mais recente (0 se não há)
  local e m=0 IFS=,
  for e in $S_REBOOTS; do [ -n "$e" ] && [ "$e" -gt "$m" ] && m=$e; done
  printf '%s' "$m"
}
count_since() {  # $1=agora $2=janela → quantas marcas têm idade <= janela (idade negativa = relógio voltou: conta)
  local e n=0 IFS=,
  for e in $S_REBOOTS; do [ -n "$e" ] && [ $(( $1 - e )) -le "$2" ] && n=$((n + 1)); done
  printf '%s' "$n"
}
drop_mark() {  # $1=marca → tira UMA ocorrência da lista
  local e out="" IFS=, gone=0
  for e in $S_REBOOTS; do
    [ -n "$e" ] || continue
    if [ "$gone" = 0 ] && [ "$e" = "$1" ]; then gone=1; continue; fi
    out="${out:+$out,}$e"
  done
  S_REBOOTS=$out
}

# ── leituras do mundo ─────────────────────────────────────────────────────────────────────────────────────────────────────────
FREE_MB=0; READ_ERR=""
read_free_mb() {  # rc 0 = FREE_MB (inteiro); rc 1 = ilegível (READ_ERR). Lê o volume de DADOS (nunca `df /`: o / do macOS é o sistema selado)
  local ov="${DR4_FREE_MB_OVERRIDE:-}" kb
  if [ -n "$ov" ]; then
    case "$ov" in *[!0-9]*) READ_ERR="leitura de disco simulada como ilegível"; return 1 ;; esac
    FREE_MB=$ov; return 0
  fi
  kb=$("$DFBIN" -k "$VOLUME" 2>/dev/null | awk 'NR==2 {print $4}')
  if ! isnum "$kb"; then READ_ERR="df -k $VOLUME não devolveu um número ('${kb:-vazio}')"; return 1; fi
  FREE_MB=$(( kb / 1024 )); return 0
}
swap_used() {  # só para o TEXTO do aviso (não decide nada): "4562M" ou "?" se não consegui ler
  local s
  s=$("$SYSCTL" -n vm.swapusage 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i+2); print v; exit } }')
  printf '%s' "${s:-?}"
}
BOOT_EPOCH=0
read_boot_epoch() {  # rc 0 = BOOT_EPOCH; rc 1 = ilegível. Token EXATO "sec" (a regex gulosa casa o "sec" de "usec" — ga-ljncyt, ga-rc7tz)
  local b="${DR4_BOOT_EPOCH:-}"
  if [ -z "$b" ]; then
    b=$("$SYSCTL" -n kern.boottime 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }')
  fi
  isnum "$b" || { READ_ERR="kern.boottime ilegível ('${b:-vazio}')"; return 1; }
  BOOT_EPOCH=$b; return 0
}

# ── pedido de reinício PENDENTE (ga-1p1i5jr.4.3) ───────────────────────────────────────────────────────────────────────────────
# Pedido aceito e o mini ainda no ar WAIT_S depois = "AINDA não caiu", não "não vai cair": um app segurando o logout pode terminar o desligamento depois. Soltar a marca
# ali perdia o cooldown e a escalada DESSA queda (só o piso de 2 h de uptime segurava o laço). Agora a marca FICA na lista (inerte: segura cooldown e teto) e o estado
# guarda pending_mark/pending_boot; quem decide é a rodada SEGUINTE, pelo kern.boottime (a tolerância BOOT_TOL_S cobre ajuste curto do relógio; reinício de verdade move >= 2 h):
#   mudou → o mini reiniciou depois do pedido: a marca era verdadeira e FICA (cooldown, teto e escalada passam a valer);
#   igual → não reiniciou: antes de marca+ATTEMPT_GAP_S espera (não escala, não pede de novo); depois, solta a marca e segue o fluxo normal.
PEND_HOLD_UNTIL=0
resolve_pending() {  # ajusta S_REBOOTS/S_PEND_* e PEND_HOLD_UNTIL (> 0 = ainda pendente, espera até esse instante). Precisa de NOW, BOOT_EPOCH e do estado já lidos; no dry-run não grava
  PEND_HOLD_UNTIL=0
  [ "$S_PEND_MARK" -gt 0 ] || return 0
  local mk=$S_PEND_MARK d hold_to
  # BOOT_EPOCH já foi lido (ilegível = rc 30 antes de chegar aqui) e S_PEND_BOOT > 0 (o state_load recusa o contrário); os dois são números, a diferença não falha
  d=$(( BOOT_EPOCH - S_PEND_BOOT )); [ "$d" -ge 0 ] || d=$(( -d ))
  if [ "$d" -gt "$BOOT_TOL_S" ]; then
    log "pedido de reinício pendente (marca $mk): o kern.boottime mudou (gravado $S_PEND_BOOT, agora $BOOT_EPOCH): o mini reiniciou depois do pedido — a marca FICA"
    S_PEND_MARK=0; S_PEND_BOOT=0
    [ "$DRY" = 1 ] || state_save || log "WARN: não gravei a pendência resolvida em $STATE — a próxima rodada confere de novo (o resultado é o mesmo)"
    return 0
  fi
  hold_to=$(( mk + ATTEMPT_GAP_S ))
  if [ "$NOW" -lt "$hold_to" ]; then PEND_HOLD_UNTIL=$hold_to; return 0; fi
  log "pedido de reinício pendente (marca $mk): kern.boottime igual ao gravado ($S_PEND_BOOT, agora $BOOT_EPOCH) e passou a espera de ${ATTEMPT_GAP_S}s — o mini NÃO reiniciou; solto a marca"
  drop_mark "$mk"; S_PEND_MARK=0; S_PEND_BOOT=0
  [ "$DRY" = 1 ] || state_save || log "WARN: não gravei a marca solta em $STATE — a próxima rodada solta de novo (o resultado é o mesmo)"
  return 0
}
hold_after_cancel() {  # cancelamento DEPOIS do aviso "reiniciando em Ns": segura DEFER_S. Sem isso a rodada seguinte reenvia o aviso e a carência enquanto a leitura oscila no limiar. Quem chama atualizou NOW
  S_DEFER_UNTIL=$(( NOW + DEFER_S ))
  state_save || log "WARN: não gravei a espera de ${DEFER_S}s em $STATE — a próxima rodada pode repetir o aviso"
}

# ── pré-checagem: o mini volta SOZINHO depois do reinício? ──────────────────────────────────────────────────────────────────────
PRE_WHY=""
precheck_env() {  # rc 0 = ok; rc 20 = reprovou (PRE_WHY); rc 30 = não consegui ler (PRE_WHY)
  local out rc cu al
  out=$("$FDESETUP" status 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { PRE_WHY="fdesetup status falhou (rc=$rc: $(printf '%s' "$out" | head -1))"; return 30; }
  case "$out" in
    *"Deferred enablement"*) PRE_WHY="FileVault tem habilitação ADIADA ($(printf '%s' "$out" | head -1)): ele liga no próximo login e o mini para na tela de senha"; return 20 ;;
    "FileVault is Off."*) ;;
    *"FileVault is On"*|*"progress"*) PRE_WHY="FileVault não está desligado ($(printf '%s' "$out" | head -1)): depois do boot o mini para na tela de senha e a cidade fica no escuro"; return 20 ;;
    *) PRE_WHY="fdesetup devolveu um texto que não reconheço ($(printf '%s' "$out" | head -1))"; return 30 ;;
  esac
  cu="${DR4_CONSOLE_USER:-}"
  [ -n "$cu" ] || cu=$("$STATBIN" -f %Su /dev/console 2>/dev/null)
  [ -n "$cu" ] || { PRE_WHY="não consegui ler o usuário do console"; return 30; }
  out=$("$DEFAULTS" read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"does not exist"*) PRE_WHY="autologin NÃO está configurado (autoLoginUser não existe): depois do boot ninguém entra na sessão e os LaunchAgents da cidade não sobem"; return 20 ;;
      *) PRE_WHY="defaults read autoLoginUser falhou (rc=$rc: $(printf '%s' "$out" | head -1))"; return 30 ;;
    esac
  fi
  al=$(printf '%s' "$out" | head -1)
  [ -n "$al" ] || { PRE_WHY="autoLoginUser veio vazio"; return 30; }
  [ "$al" = "$cu" ] || { PRE_WHY="autologin é '$al' mas o console é de '$cu': o mini não volta na sessão que roda a cidade"; return 20; }
  out=$("$LAUNCHCTL" print "gui/$(id -u)/$POSTCHECK_LABEL" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc:$out" in
      113:*|*"Could not find service"*) PRE_WHY="o postcheck pós-boot ($POSTCHECK_LABEL) NÃO está carregado: um reinício sem conferência depois não se distingue de um mini que não voltou inteiro"; return 20 ;;
      *) PRE_WHY="launchctl print $POSTCHECK_LABEL falhou (rc=$rc: $(printf '%s' "$out" | head -1))"; return 30 ;;
    esac
  fi
  if [ -z "${DR4_REBOOT_CMD:-}" ] && [ ! -x "$OSASCRIPT" ]; then PRE_WHY="$OSASCRIPT não existe ou não executa: não há como pedir o reinício sem sudo"; return 20; fi
  return 0
}

# ── guardas: o MESMO código do reinício noturno ───────────────────────────────────────────────────────────────────────────────
NIGHTLY_ERR=""; NIGHTLY_LOADED=0
extract_block() {  # $1=arquivo $2=NOME → imprime o bloco entre NOME-START e NOME-END (as duas linhas incluídas). Exatamente 1 início e 1 fim, senão rc 3
  awk -v s="$2-START" -v e="$2-END" '
    function tok(t,   i) {  # a sentinela é o TOKEN inteiro: depois dele só pode vir espaço, tab ou fim de linha ("-STARTX" não é "-START")
      i = index($0, ":" t)
      return substr($0, 1, 1) == "#" && i > 0 && substr($0, i + length(t) + 1, 1) ~ /^[ \t]?$/
    }
    tok(s) { n_s++; on = 1 }
    on { print }
    tok(e) { n_e++; on = 0 }
    END { if (n_s != 1 || n_e != 1) exit 3 }' "$1"
}
load_nightly_blocks() {  # define scraper_daily_state e DOLT_MAINT_PATTERN_DEFAULT a partir do nightly. Falha → NIGHTLY_ERR (as duas guardas viram "não sei")
  [ "$NIGHTLY_LOADED" = 1 ] && return 0
  local blk
  if [ ! -r "$NIGHTLY" ]; then NIGHTLY_ERR="$NIGHTLY não legível"; return 1; fi
  blk=$(extract_block "$NIGHTLY" SCRAPER-DAILY-GUARD) || { NIGHTLY_ERR="sentinela SCRAPER-DAILY-GUARD sumiu ou duplicou em $NIGHTLY (a guarda do scraper mudou de forma)"; return 1; }
  eval "$blk"
  declare -F scraper_daily_state >/dev/null 2>&1 || { NIGHTLY_ERR="scraper_daily_state não foi definida pelo bloco extraído"; return 1; }
  blk=$(extract_block "$NIGHTLY" DOLT-MAINT-PATTERN) || { NIGHTLY_ERR="sentinela DOLT-MAINT-PATTERN sumiu ou duplicou em $NIGHTLY"; return 1; }
  eval "$blk"
  [ -n "${DOLT_MAINT_PATTERN_DEFAULT:-}" ] || { NIGHTLY_ERR="DOLT_MAINT_PATTERN_DEFAULT vazio depois da extração"; return 1; }
  NIGHTLY_LOADED=1
  return 0
}

G_STATE=""; G_WHY=""
guard_calls() {  # ligação em curso (pix + voicebot), lida em 3 estados
  G_STATE="unknown"; G_WHY=""
  local rc line st=""
  if [ ! -r "$CALLS_PY" ]; then G_WHY="$CALLS_PY não legível"; return 0; fi
  run_bounded "$GUARD_TIMEOUT_S" "$PY" -I "$CALLS_PY" --max-age-min "$CALL_MAX_AGE_MIN"; rc=$?
  line=$(out_raw)
  case "$line" in *$'\t'*) st=${line%%$'\t'*}; line=${line#*$'\t'} ;; esac
  line=$(printf '%s' "$line" | tr -d '\r')
  # o contrato do leitor é 0/1/2 COM a linha "estado<TAB>detalhe": rc 1 também é traceback do python, então o rc só vale junto com o estado que o próprio leitor imprime (senão é "não sei")
  case "$rc:$st" in
    0:ok) G_STATE="ok" ;;
    1:block) G_STATE="block" ;;
    *) G_STATE="unknown"; line="rc=$rc: ${line:-(sem saída)}" ;;
  esac
  G_WHY=$line; rb_clean; return 0
}
guard_sender() {  # envio em voo (central_sender_restart_safe.py: 0 pode · 1 em voo · 2 não sei)
  G_STATE="unknown"; G_WHY=""
  local rc line
  if [ ! -r "$SENDER_PY" ]; then G_WHY="central_sender_restart_safe.py não legível em $SENDER_PY — não sei se há envio em voo"; return 0; fi
  run_bounded "$GUARD_TIMEOUT_S" "$PY" "$SENDER_PY"; rc=$?
  line=$(out_line)
  case "$rc" in
    0) G_STATE="ok"; G_WHY="sem envio em voo" ;;
    # rc 1 também é o que um traceback do python devolve: só é "em voo" se for a mensagem do próprio script (a do traceback é "não sei", e não vira bloqueio de mentira)
    1) case "$line" in
         "central_sender_restart_safe:"*"em voo"*) G_STATE="block"; G_WHY=$line ;;
         *) G_STATE="unknown"; G_WHY="rc=1 sem a mensagem do script: $line" ;;
       esac ;;
    *) G_STATE="unknown"; G_WHY="rc=$rc: $line" ;;
  esac
  rb_clean; return 0
}
guard_dolt() {  # manutenção do Dolt no meio (gc/backup/push...) — pgrep: 0 achou · 1 não achou · outro = não sei
  G_STATE="unknown"; G_WHY=""
  if ! load_nightly_blocks; then G_WHY=$NIGHTLY_ERR; return 0; fi
  local pat="${DR4_DOLT_MAINT_PATTERN:-$DOLT_MAINT_PATTERN_DEFAULT}" out rc
  out=$("$PGREP" -fl "$pat" 2>&1); rc=$?
  case "$rc" in
    1) G_STATE="ok"; G_WHY="nenhuma manutenção do Dolt em curso" ;;
    0) G_STATE="block"; G_WHY="manutenção do Dolt em curso: $(printf '%s' "$out" | tr '\n' ';' | cut -c1-200)" ;;
    *) G_STATE="unknown"; G_WHY="pgrep falhou (rc=$rc: $(printf '%s' "$out" | head -1))" ;;
  esac
  return 0
}
guard_scraper() {  # rodada do property_scrapers em curso (a função do noturno: running / clear / unknown)
  G_STATE="unknown"; G_WHY=""
  if ! load_nightly_blocks; then G_WHY=$NIGHTLY_ERR; return 0; fi
  SCRAPER_DAILY_STATE=""; SCRAPER_DAILY_REASON=""
  scraper_daily_state
  case "${SCRAPER_DAILY_STATE:-}" in
    clear) G_STATE="ok"; G_WHY="${SCRAPER_DAILY_REASON:-sem rodada}" ;;
    running) G_STATE="block"; G_WHY="${SCRAPER_DAILY_REASON:-rodada em curso}" ;;
    *) G_STATE="unknown"; G_WHY="${SCRAPER_DAILY_REASON:-sem motivo} (estado '${SCRAPER_DAILY_STATE:-vazio}')" ;;
  esac
  return 0
}

GUARDS_SUMMARY=""; BLOCK_NAMES=""; BLOCK_WHY=""; UNK_NAMES=""; UNK_WHY=""
run_guards() {  # avalia TODAS (mesmo depois de uma bloquear: uma linha mostra tudo o que está no caminho). rc 0 = todas ok · 1 = alguma bloqueia · 2 = nenhuma bloqueia mas alguma não deu pra ler
  GUARDS_SUMMARY=""; BLOCK_NAMES=""; BLOCK_WHY=""; UNK_NAMES=""; UNK_WHY=""
  local g
  for g in calls sender dolt scraper; do
    "guard_$g"
    GUARDS_SUMMARY="$GUARDS_SUMMARY${GUARDS_SUMMARY:+ · }$g=$G_STATE"
    case "$G_STATE" in
      ok) ;;
      block) BLOCK_NAMES="$BLOCK_NAMES${BLOCK_NAMES:+, }$g"; BLOCK_WHY="$BLOCK_WHY${BLOCK_WHY:+; }$g: $G_WHY" ;;
      *) UNK_NAMES="$UNK_NAMES${UNK_NAMES:+, }$g"; UNK_WHY="$UNK_WHY${UNK_WHY:+; }$g: $G_WHY" ;;
    esac
  done
  log "guardas: $GUARDS_SUMMARY"
  [ -n "$BLOCK_NAMES" ] && return 1
  [ -n "$UNK_NAMES" ] && return 2
  return 0
}

# ── avisos ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
alert_throttled() {  # $1=título $2=corpo — push no máximo 1 por DEFER_NOTIFY_S (um mini com guarda travada por horas não vira metralhadora)
  local t=$1 body=$2 n
  n=$(now)
  if [ "$S_DEFER_NOTIFY" -gt 0 ] && [ $(( n - S_DEFER_NOTIFY )) -ge 0 ] && [ $(( n - S_DEFER_NOTIFY )) -lt "$DEFER_NOTIFY_S" ]; then
    log "aviso '$t' suprimido (último há $(( n - S_DEFER_NOTIFY ))s < ${DEFER_NOTIFY_S}s)"; return 0
  fi
  # o carimbo só vale com a entrega CONFIRMADA: aviso que não saiu e foi carimbado = 1 h de silêncio sem ninguém saber
  if send_notify 5 "$t" "$body"; then S_DEFER_NOTIFY=$n; else log "WARN: aviso '$t' NÃO entregue — não carimbo defer_notify_ts, tento de novo na próxima rodada"; fi
}
ESC_NOTE=""   # o que a escalada fez, para o texto da linha de stdout ("escalado" só se saiu mesmo)
escalate_low_after_reboot() {  # $1=última marca de reinício $2=motivo. UMA vez por reinício (esc_for): o disco segue baixo e este degrau NÃO reinicia de novo
  [ "$DRY" = 1 ] && { ESC_NOTE="dry-run: não escalo"; return 0; }
  [ "$S_ESC_FOR" = "$1" ] && { log "escalada deste reinício ($1) já foi feita — não repito"; ESC_NOTE="escalada deste reinício já feita"; return 0; }
  local ok=0
  send_notify 5 "Disco: segue baixo depois do reinício automático" "Livre ${FREE_MB} MB. $2 O D4 NÃO reinicia de novo. Precisa de um humano: o que está comendo o disco depois do boot? Log: $LOG" && ok=1
  send_mail "Disco: D4 não reinicia de novo e o disco segue baixo (livre ${FREE_MB} MB)" "O D4 da escada de disco (ga-1p1i5jr.4) recusou um novo reinício automático: $2 Livre agora: ${FREE_MB} MB. Isto é o fim da escada: precisa de um humano. Estado: $STATE · log: $LOG" && ok=1
  if [ "$ok" = 0 ]; then log "ERROR: escalada NÃO entregue (notify e mail falharam) — não gravo esc_for, repito na próxima rodada"; ESC_NOTE="escalada NÃO entregue"; return 0; fi
  ESC_NOTE="escalado"; S_ESC_FOR=$1
  state_save || log "WARN: não gravei esc_for em $STATE — a escalada pode se repetir na próxima rodada"
}

usage() { echo "uso: $(basename "$0") --run | --dry-run" >&2; exit 2; }

# ═══ principal ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
  --run) [ "$#" -eq 1 ] || usage ;;
  --dry-run) [ "$#" -eq 1 ] || usage; DRY=1 ;;
  *) usage ;;
esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec 2>>"$LOG" || exec 2>/dev/null   # stderr nunca suja o stdout (o orquestrador lê a PRIMEIRA linha das duas juntas)
[ -z "$CFG_WARN" ] || log "WARN: variável(is) DR4_ que não são número caíram no padrão:$CFG_WARN"
NOW=$(now)
log "início ($([ "$DRY" = 1 ] && echo dry-run || echo run)) pid=$$"

# 1 — interruptor (o mesmo do orquestrador; vale também no dry-run: é o que o humano usa pra mandar tudo calar)
if [ -e "$OFF" ]; then emit 10 "interruptor ligado ($OFF) — não leio nem ajo"; fi
read_boot_epoch || emit 30 "não consegui ler quando o mini subiu ($READ_ERR) — NÃO ajo"

# 2 — instância única (só no --run; o dry-run só lê) + estado
if [ "$DRY" = 0 ]; then
  mkdir -p "$(dirname "$LOCKD")" 2>/dev/null
  if ! mkdir "$LOCKD" 2>/dev/null; then
    lp=$(cat "$LOCKD/pid" 2>/dev/null); lm=$("$STATBIN" -f %m "$LOCKD" 2>/dev/null)
    # Trava criada ANTES do boot atual é de uma instância que morreu com ele, mesmo que o pid tenha sido reaproveitado por outro processo (sem isto o D4
    # ficaria recusando para sempre, em silêncio). Data da trava ilegível = não consigo provar que é velha: vale como viva (lado inerte).
    if isnum "$lp" && kill -0 "$lp" 2>/dev/null && ! { isnum "$lm" && [ "$lm" -lt "$BOOT_EPOCH" ]; }; then emit 10 "outra instância em curso (pid $lp) — repito depois"; fi
    # pid morto ou ilegível = trava velha de uma instância que caiu (o desligamento mata o D4 sem soltar a trava). Janela de dois D4 ao
    # mesmo tempo: microssegundos entre o mkdir e o echo do pid; o pior caso são dois pedidos de reinício, que viram um só.
    log "trava velha ($LOCKD, pid='${lp:-vazio}') — tomo"
    rm -f "$LOCKD/pid" 2>/dev/null; rmdir "$LOCKD" 2>/dev/null
    mkdir "$LOCKD" 2>/dev/null || emit 10 "outra instância ganhou a trava ($LOCKD) — repito depois"
  fi
  LOCK_HELD=1
  echo $$ > "$LOCKD/pid" 2>/dev/null
fi
state_load || emit 30 "não consegui ler o estado do D4 ($STATE_ERR) — NÃO ajo"
resolve_pending   # pedido de reinício de uma rodada anterior que não derrubou o mini a tempo: decide pelo kern.boottime ANTES de qualquer cooldown olhar a marca

# 3 — o disco ainda está abaixo do limiar? (o orquestrador decidiu há minutos; a leitura pode ter mudado)
read_free_mb || emit 30 "não consegui ler o disco ($READ_ERR) — NÃO ajo"
if [ "$FREE_MB" -ge "$MB" ]; then emit 10 "disco recuperou (livre=${FREE_MB}MB >= ${MB}MB) — nada a fazer"; fi
TIER="sustentado (< $((MB / 1024)) GB)"; [ "$FREE_MB" -lt "$HARD_MB" ] && TIER="crítico (< $((HARD_MB * 10 / 1024 / 10)),$((HARD_MB * 10 / 1024 % 10)) GB)"

# 3b — pedido anterior ainda PENDENTE (o mini não reiniciou até agora, mas o desligamento pode estar só lento): não escala, não pede de novo. Vem DEPOIS do disco (recuperou vence)
# e ANTES do cooldown (a marca pendente ainda está na lista e o cooldown leria "reiniciou há N min" de um mini que pode não ter reiniciado)
HOLD_NOTE=""
if [ "$PEND_HOLD_UNTIL" -gt 0 ]; then
  PEND_TXT="o pedido de reinício de $(hhmm "$S_PEND_MARK") ainda está PENDENTE: o mini não reiniciou até agora (kern.boottime igual) mas o desligamento pode estar só lento; confiro de novo depois de $(hhmm "$PEND_HOLD_UNTIL") e só então solto a marca"
  if [ "$DRY" = 0 ]; then emit 10 "$PEND_TXT — repito depois; livre=${FREE_MB}MB"; fi
  drop_mark "$S_PEND_MARK"   # só em memória (no dry-run nada é gravado): mostra o resto do que o --run faria depois da pendência
  HOLD_NOTE=" [no --run: $PEND_TXT]"
fi

# 4 — cooldown, teto diário, mini recém-subido
LAST=$(last_reboot)
if [ "$LAST" -gt 0 ]; then
  age=$(( NOW - LAST ))
  if [ "$age" -lt "$COOLDOWN_S" ]; then
    why="O último reinício automático foi há $(( age / 60 )) min (cooldown de $(( COOLDOWN_S / 3600 )) h)."
    escalate_low_after_reboot "$LAST" "$why"
    emit 10 "cooldown: $why O disco segue em ${FREE_MB}MB: NÃO reinicio de novo ($ESC_NOTE)"
  fi
fi
n24=$(count_since "$NOW" "$DAY_WINDOW_S")
if [ "$n24" -ge "$DAY_CAP" ]; then
  why="Já houve $n24 reinício(s) automático(s) nas últimas $(( DAY_WINDOW_S / 3600 )) h (teto $DAY_CAP)."
  escalate_low_after_reboot "$LAST" "$why"
  emit 10 "teto diário: $why O disco segue em ${FREE_MB}MB: NÃO reinicio de novo ($ESC_NOTE)"
fi
up=$(( NOW - BOOT_EPOCH ))
if [ "$up" -lt "$MIN_UPTIME_S" ]; then
  emit 10 "mini no ar há $(( up / 60 )) min (< $(( MIN_UPTIME_S / 60 )) min, qualquer causa): um reinício agora não ajudaria e abre laço — repito depois"
fi

# 5 — espera: 10 min depois que uma guarda adiou, 30 min depois de um pedido que não derrubou o mini (no dry-run só informa e segue, pra mostrar o resto)
if [ "$S_DEFER_UNTIL" -gt "$NOW" ]; then
  if [ "$DRY" = 0 ]; then emit 10 "adiado até $(hhmm "$S_DEFER_UNTIL") (espera depois de uma guarda, de um aviso cancelado ou de um pedido que não derrubou o mini) — repito depois"; fi
  HOLD_NOTE="$HOLD_NOTE [no --run: adiado até $(hhmm "$S_DEFER_UNTIL")]"
fi

# 6 — o mini volta sozinho?
precheck_env; prc=$?
case "$prc" in
  0) ;;
  20) emit 20 "pré-checagem reprovou: $PRE_WHY — NÃO reinicio" ;;
  *) emit 30 "pré-checagem ilegível: $PRE_WHY — NÃO reinicio" ;;
esac

# 7 — guardas
run_guards; grc=$?
case "$grc" in
  1)
    if [ "$DRY" = 0 ]; then
      S_DEFER_UNTIL=$(( NOW + DEFER_S ))
      alert_throttled "Disco: reinício adiado (${BLOCK_NAMES})" "Livre ${FREE_MB} MB (${TIER}), mas o D4 não reinicia agora: ${BLOCK_WHY}. Tento de novo em $(( DEFER_S / 60 )) min (às $(hhmm "$S_DEFER_UNTIL"))."
      state_save || log "WARN: não gravei a espera em $STATE — repito a avaliação a cada rodada"
    fi
    emit 10 "adiado — guarda(s) bloqueando (${BLOCK_NAMES}): ${BLOCK_WHY}${UNK_NAMES:+ | sem leitura: $UNK_NAMES}; livre=${FREE_MB}MB${HOLD_NOTE}" ;;
  2)
    if [ "$DRY" = 0 ]; then
      alert_throttled "Disco: o D4 não consegue ler uma guarda" "Livre ${FREE_MB} MB (${TIER}) e o D4 NÃO reinicia porque não consegue ler: ${UNK_WHY}. Sem a leitura, não sei se há ligação ou envio em curso."
      state_save || log "WARN: não gravei o aviso em $STATE"
    fi
    emit 30 "não consegui ler guarda(s) (${UNK_NAMES}): ${UNK_WHY} — NÃO reinicio; livre=${FREE_MB}MB" ;;
esac

SWAP=$(swap_used)
if [ "$DRY" = 1 ]; then
  emit 0 "reiniciaria agora (livre=${FREE_MB}MB ${TIER}, swap=${SWAP}; ${GUARDS_SUMMARY})${HOLD_NOTE}"
fi

# 8 — o reinício de verdade: aviso → carência → releitura → grava e confere → pede
# O aviso é CONDIÇÃO do reinício, não cortesia (decisão do Athos: "e AVISA"): sem ninguém avisado a carência para abortar é teatro. Não entregou (notify rc≠0 ou prazo
# estourado = "não sei") → 2º canal, o mail ao Mayor; os dois falharam → não reinicia (inerte), espera e tenta de novo. Nunca "aviso enviado" sem confirmação.
WARN_TXT="Livre ${FREE_MB} MB (${TIER}), swap ${SWAP}. Guardas ok: ${GUARDS_SUMMARY}. Volto em ~2 min (auto-login + postcheck). Para ABORTAR agora: touch ${OFF}"
WARN_VIA="notify"
if ! send_notify 5 "Disco: reiniciando o mini em ${GRACE_S}s" "$WARN_TXT"; then
  if send_mail "Disco: reiniciando o mini em ${GRACE_S}s (o push NÃO foi confirmado)" "$WARN_TXT"; then WARN_VIA="mail ao Mayor (o push NÃO foi confirmado)"
  else
    S_DEFER_UNTIL=$(( NOW + DEFER_S )); state_save || log "WARN: não gravei a espera em $STATE"
    emit 30 "não consegui AVISAR (notify e mail ao Mayor falharam) — NÃO reinicio; tento de novo às $(hhmm "$S_DEFER_UNTIL"); livre=${FREE_MB}MB"
  fi
fi
log "aviso entregue por ${WARN_VIA}; carência de ${GRACE_S}s (o interruptor $OFF aborta)"
g=0
while [ "$g" -lt "$GRACE_S" ]; do
  [ -e "$OFF" ] && break
  sleep 1; g=$((g + 1))
done
if [ -e "$OFF" ]; then emit 10 "interruptor ligado durante a carência — NÃO reiniciei"; fi

# TODO cancelamento daqui até a marca vale a regra da ga-1p1i5jr.4.3: segura DEFER_S (hold_after_cancel) antes de sair. Quem já mandou "reiniciando em Ns" e cancela sem segurar
# faz a rodada seguinte mandar o aviso de novo, a cada tick, enquanto a leitura oscila no limiar. (O interruptor acima não segura: é um humano mandando calar, e o passo 1 o respeita.
# Falha ao gravar a marca, mais abaixo, também não segura: o estado que não grava a marca não grava a espera.)
NOW=$(now)
# vazio → não existe (a leitura é um número ou falha); falhou/ilegível → rc 30, NÃO reinicia, segura DEFER_S
if ! read_free_mb; then
  hold_after_cancel
  emit 30 "não consegui reler o disco depois do aviso ($READ_ERR) — NÃO reinicio; tento de novo às $(hhmm "$S_DEFER_UNTIL")"
fi
if [ "$FREE_MB" -ge "$MB" ]; then
  hold_after_cancel
  send_notify 4 "Disco: reinício cancelado, o disco recuperou" "Durante a carência o livre subiu para ${FREE_MB} MB (>= ${MB} MB). Não reiniciei. Se cair de novo, só reavalio às $(hhmm "$S_DEFER_UNTIL")."
  emit 10 "disco recuperou durante a carência (livre=${FREE_MB}MB) — NÃO reiniciei; espera até $(hhmm "$S_DEFER_UNTIL")"
fi
# a pré-checagem do passo 6 vale ANTES do aviso; o que ela leu (FileVault, autologin, postcheck, osascript) pode ter mudado nos 60 s de carência, e um mini que
# não volta sozinho é o pior desfecho. vazio → não existe (cada leitura devolve texto ou rc); reprovou → rc 20; falhou/ilegível → rc 30; nos dois NÃO reinicia e segura DEFER_S
precheck_env; prc=$?
case "$prc" in
  0) ;;
  20)
    hold_after_cancel
    send_notify 5 "Disco: reinício cancelado, a pré-checagem reprovou depois do aviso" "Depois do aviso: ${PRE_WHY}. NÃO reiniciei. Tento de novo às $(hhmm "$S_DEFER_UNTIL")."
    emit 20 "pré-checagem reprovou depois da carência: $PRE_WHY — NÃO reiniciei; espera até $(hhmm "$S_DEFER_UNTIL")" ;;
  *)
    hold_after_cancel
    send_notify 5 "Disco: reinício cancelado, pré-checagem ilegível depois do aviso" "Depois do aviso não consegui ler: ${PRE_WHY}. NÃO reiniciei. Tento de novo às $(hhmm "$S_DEFER_UNTIL")."
    emit 30 "pré-checagem ilegível depois da carência: $PRE_WHY — NÃO reinicio; espera até $(hhmm "$S_DEFER_UNTIL")" ;;
esac
run_guards; grc=$?
case "$grc" in
  1)
    S_DEFER_UNTIL=$(( NOW + DEFER_S ))
    send_notify 5 "Disco: reinício cancelado na última checagem (${BLOCK_NAMES})" "Depois do aviso, a guarda mudou: ${BLOCK_WHY}. NÃO reiniciei. Tento de novo às $(hhmm "$S_DEFER_UNTIL")." && S_DEFER_NOTIFY=$NOW
    state_save || log "WARN: não gravei a espera em $STATE"
    emit 10 "adiado na releitura final — guarda(s) bloqueando (${BLOCK_NAMES}): ${BLOCK_WHY}; livre=${FREE_MB}MB" ;;
  2)
    hold_after_cancel
    send_notify 5 "Disco: reinício cancelado, guarda ilegível na última checagem" "Depois do aviso não consegui ler: ${UNK_WHY}. NÃO reiniciei. Tento de novo às $(hhmm "$S_DEFER_UNTIL")."
    emit 30 "não consegui reler guarda(s) (${UNK_NAMES}): ${UNK_WHY} — NÃO reinicio; espera até $(hhmm "$S_DEFER_UNTIL")" ;;
esac

# a marca vai para o disco ANTES do pedido e é CONFERIDA: o pedido derruba este processo (nada escrito depois conta), e reinício sem marca
# gravada é o caminho do laço. Não gravou = não reinicia.
MARK=$NOW
prune_reboots "$NOW"
S_REBOOTS="${S_REBOOTS:+$S_REBOOTS,}$MARK"; S_DEFER_UNTIL=0
if ! state_save; then
  drop_mark "$MARK"
  emit 20 "não consegui gravar o estado ($STATE) — sem a marca do reinício eu poderia reiniciar em laço; NÃO reinicio"
fi
state_load || emit 20 "gravei o estado mas não consegui relê-lo ($STATE_ERR) — NÃO reinicio (a marca pode estar no disco: legível, conta como cooldown; ilegível, a próxima rodada sai 30 — nos dois casos NÃO reinicia)"
case ",$S_REBOOTS," in
  *",$MARK,"*) ;;
  *) emit 20 "gravei o estado mas a marca $MARK não está nele quando releio — NÃO reinicio" ;;
esac
log "REINÍCIO AUTOMÁTICO (D4, decisão do Athos 01/11) marca=$MARK livre=${FREE_MB}MB ${TIER} swap=${SWAP} no ar há $(( (MARK - BOOT_EPOCH) / 60 )) min; guardas: ${GUARDS_SUMMARY}. Marca gravada e conferida; pedindo o reinício"

if [ -n "${DR4_REBOOT_CMD:-}" ]; then
  run_bounded "$REBOOT_TIMEOUT_S" env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash -c "$DR4_REBOOT_CMD"; rrc=$?
elif [ "${DR4_NO_REAL_REBOOT:-0}" = 1 ]; then
  RB_OUT=""; rrc=126; log "DR4_NO_REAL_REBOOT=1 e nenhum DR4_REBOOT_CMD: o comando de verdade está proibido aqui"
else
  run_bounded "$REBOOT_TIMEOUT_S" env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$OSASCRIPT" -e 'tell application "loginwindow" to «event aevtrrst»'; rrc=$?
fi
# rc 124 = o pedido estourou o prazo: NÃO sei se o evento chegou ao loginwindow (o mini pode cair daqui a pouco). Terceiro estado: mantém a marca (soltá-la
# perderia o cooldown se ele cair) e espera como no rc 0. Só um rc que o comando DEVOLVEU (erro de entrega, permissão) é falha definida.
REQ_DESC="aceito (rc 0)"   # só o que se SABE: rc 124 é "não sei se pegou", e o log/stdout/aviso abaixo dizem isso, não "aceito"
if [ "$rrc" -eq 124 ]; then REQ_DESC="enviado, mas estourou o prazo (rc 124: não sei se pegou)"; log "WARN: o pedido de reinício estourou ${REBOOT_TIMEOUT_S}s (rc 124) — não sei se pegou; espero como se tivesse pegado"; fi
if [ "$rrc" -ne 0 ] && [ "$rrc" -ne 124 ]; then
  why="o pedido de reinício falhou (rc=$rrc: $(out_line))"; rb_clean
  drop_mark "$MARK"; S_DEFER_UNTIL=$(( NOW + ATTEMPT_GAP_S )); state_save || log "ERROR: não consegui desfazer a marca $MARK em $STATE — fica contando (inerte: bloqueia por ${COOLDOWN_S}s)"
  send_notify 5 "Disco: o reinício automático FALHOU" "Livre ${FREE_MB} MB. ${why}. O mini NÃO reiniciou. Preciso de um humano. Log: $LOG"
  emit 20 "$why — o mini NÃO reiniciou; desfiz a marca"
fi
rb_clean
log "pedido ${REQ_DESC}; esperando até ${WAIT_S}s o mini cair — se este processo continuar vivo, o mini AINDA não caiu (pode estar só lento)"
w=0
while [ "$w" -lt "$WAIT_S" ]; do sleep 1; w=$((w + 1)); done
# chegou aqui = o mini AINDA não caiu (≠ "não vai cair": um logout lento pode terminar depois dos ${WAIT_S}s). A marca FICA na lista e vira PENDENTE (ga-1p1i5jr.4.3): quem
# decide se o pedido pegou é a rodada de depois de marca+ATTEMPT_GAP_S, pelo kern.boottime (resolve_pending). Este processo só viu o mini vivo, e isso não prova "não reiniciou".
# Se não conseguir gravar a pendência, a marca (já gravada e conferida acima) fica como reinício comum: bloqueia por COOLDOWN_S, o lado inerte.
S_PEND_MARK=$MARK; S_PEND_BOOT=$BOOT_EPOCH; S_DEFER_UNTIL=$(( NOW + ATTEMPT_GAP_S ))
state_save || log "ERROR: não consegui gravar a pendência da marca $MARK em $STATE — ela fica como reinício comum (inerte: bloqueia por ${COOLDOWN_S}s)"
send_notify 5 "Disco: pedi o reinício e o mini NÃO caiu" "Livre ${FREE_MB} MB. O pedido foi ${REQ_DESC}, e o mini continuava no ar ${WAIT_S}s depois (um app segurando o logout?). A marca fica PENDENTE e conta para cooldown e teto: se o mini cair mais tarde, o reinício vale; se na rodada de depois das $(hhmm "$S_DEFER_UNTIL") o kern.boottime não tiver mudado, solto a marca e tento de novo. Log: $LOG"
emit 20 "pedido de reinício ${REQ_DESC}; o mini continuou no ar por ${WAIT_S}s — NÃO reiniciou (até agora); marca PENDENTE: a rodada de depois das $(hhmm "$S_DEFER_UNTIL") confere o kern.boottime (mudou = vale; igual = solto a marca e tento de novo)"
