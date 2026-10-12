#!/usr/bin/env bash
# rea-run.sh — roda um comando PESADO de REA (rea, jadx, ghidra...) sem derrubar a máquina: MBP primeiro; no mini só com
#   trava de 1 execução, folga de disco/swap e scratch apagado no fim.
#
# Contents
#   Por quê · Uso · Códigos de saída · Como funciona · O que NÃO faz
#
# POR QUÊ (programa REA, épico ga-oe7o1p; ga-szz40p): REA abre Chrome/Ghidra/JVM e o mini vive no limite (11/10: swap alto,
#   disco crítico). As regras do programa — 10 GB livres, swap até 6 GB, nenhum outro `rea` ao mesmo tempo, capturas em scratch
#   apagado no fim — ficam aqui em código, em vez de depender de cada sessão lembrar.
#
# USO
#   rea-run.sh [--local] [--wait-s N] [--push P]... [--pull REL:LOCAL]... [--env K=V]... -- <comando> [args]
#        (sem --local: tenta o MBP via `mbp-run.sh --exec` e só cai para o mini nos códigos 96..99 dele; --push copia P para
#         ./in/ do scratch, --pull traz REL do scratch para LOCAL antes da limpeza, --env exporta K=V ao comando. Para
#         redirecionar saída use `-- sh -c 'rea ... > out.json'`.)
#   rea-run.sh --check          # mostra disco, swap e outro `rea` e sai (0 pode rodar · 92 sem folga · 93 não consegui ler)
#
#   --local é OBRIGATÓRIO quando o comando fala com algo do mini (o Chrome descartável em 127.0.0.1:$PORT do recon web da
#   skill rea-scraper-first): no MBP esse endereço não existe. APK, Electron, nativo e Ghidra são o caso do MBP.
#
# CÓDIGOS DE SAÍDA — o código do comando é propagado; os abaixo são do próprio wrapper (a mensagem `rea-run:` no stderr e o
#   campo "reason" do log dizem qual foi). Nunca emitimos 96..99: para quem chama, esses são "rode local" do mbp-run.
#   0..90   código do comando (MBP ou mini)
#   91      esperou o orçamento (--wait-s, padrão 1800 s) e a trava ou outro `rea` continuou ocupando
#   92      RECUSADO: sem folga — disco livre < 10 GB ou swap usado > 6144 MB (ou, em --check, outro `rea` rodando)
#   93      não consegui olhar ou preparar: df/sysctl/pgrep ilegível, trava ou scratch não criáveis, configuração inválida,
#           ou o comando saiu 0 mas um --pull pedido falhou (o resultado não chegou). É o terceiro estado: "não sei" NUNCA
#           vira "pode rodar", e "não veio" nunca vira rc 0. (Se o comando já saiu != 0, esse rc é mantido e o log marca pull-falhou.)
#   94      uso errado (sem comando, opção desconhecida, --pull com caminho absoluto ou `..`, --push que não existe)
#   124     o comando passou de REA_RUN_TIMEOUT_S (padrão 3600 s) e foi encerrado
#   128+n   o wrapper recebeu o sinal n; o comando e seus filhos foram encerrados e o scratch apagado
#
# COMO FUNCIONA
#   MBP: `mbp-run.sh --exec ... -- cmd` (chave, saúde do MBP, slot e limpeza do scratch remoto são dele). rc 96..99 → mini.
#        ATENÇÃO: o rc 98 também sai quando o ssh cai NO MEIO da execução; nesse caso o comando roda de novo no mini.
#        Use só comando de leitura/recon (idempotente), que é o caso do REA.
#   mini: (1) checa disco/swap já de cara (não vale esperar a trava para ser recusado depois) → (2) pega a trava
#        (mkdir atômico em $CITY/.gc/run/rea-run.lock, dono = pid + hora de início do processo; dono morto ou pid
#        reaproveitado é reaped) e espera até --wait-s → (3) espera não haver outro `rea` rodando (rodado por fora do
#        wrapper; só processo `node .../bin/rea` conta, não o texto "bin/rea" no argumento de outro processo) → (4) checa disco/swap DE NOVO, já sob a trava → (5) apaga scratch órfão de execução que morreu →
#        (6) cria scratch 0700 fora de qualquer repo → (7) roda o comando com cwd = scratch, nice 10, timeout e
#        $REA_RUN_SCRATCH → (8) --pull → (9) apaga o scratch (também em erro, timeout, INT/TERM/HUP) e solta a trava.
#   Log: $CITY/.gc/logs/rea-run.jsonl — uma linha por execução/recusa, só o NOME do comando e o nº de argumentos (argumentos
#        podem carregar URL/segredo).
#
# O QUE NÃO FAZ: não classifica o que é "pesado" (quem chama decide); não mata Chrome que o comando deixou vivo fora da
#   árvore dele; SIGKILL no wrapper não limpa — o scratch órfão é apagado na próxima execução (passo 5) e a trava morta
#   é reaped pelo dono morto.
set -o pipefail
set -u

CITY=${REA_RUN_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
MBP_RUN=${REA_RUN_MBP_RUN:-$CITY/scripts/mbp-run.sh}
LOG="$CITY/.gc/logs/rea-run.jsonl"
LOCK_DIR=${REA_RUN_LOCK_DIR:-$CITY/.gc/run/rea-run.lock}
SCRATCH_ROOT=${REA_RUN_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rea-run-$(id -u)}
SCRATCH_ROOT=${SCRATCH_ROOT//\/\//\/}
DF_BIN=${REA_RUN_DF:-df}
DF_PATH=${REA_RUN_DF_PATH:-/System/Volumes/Data}
SYSCTL_BIN=${REA_RUN_SYSCTL:-sysctl}
PGREP_BIN=${REA_RUN_PGREP:-pgrep}
# "outro rea" = processo node cujo script é .../bin/rea (ou scripts/rea.mjs). Ancorado no início da linha de comando: o texto
# "bin/rea " dentro do argumento de outro processo (um `claude -p` com esta regra no prompt, um `sh -c echo`) NÃO conta, senão
# a trava de "nenhum outro rea" ficaria presa para sempre. O `pgrep -fl 'bin/rea '` solto do programa casa esses falsos e
# perde `node bin/rea` sem argumentos.
PGREP_PATTERN=${REA_RUN_PGREP_PATTERN:-'^[^ ]*node( --[^ ]+)* [^ ]*(/bin/rea|/scripts/rea\.mjs)( |$)'}
MIN_FREE_GB=${REA_RUN_MIN_FREE_GB:-10}
MAX_SWAP_MB=${REA_RUN_MAX_SWAP_MB:-6144}
WAIT_S=${REA_RUN_WAIT_S:-1800}
RUN_TIMEOUT=${REA_RUN_TIMEOUT_S:-3600}
POLL_S=${REA_RUN_POLL_S:-1}
KILL_GRACE_S=${REA_RUN_KILL_GRACE_S:-3}
LOCK_ORPHAN_S=${REA_RUN_LOCK_ORPHAN_S:-30}   # trava sem arquivo de dono mais velha que isto: quem a criou morreu entre o mkdir e a escrita
NICE=${REA_RUN_NICE:-10}
umask 077

say() { printf 'rea-run: %s\n' "$*" >&2; }
usage() { sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' >&2; }
isnum() { [ "$1" -ge 0 ] 2>/dev/null; }   # inteiro sem sinal; vazio, texto e "1.5" NÃO são número

# ---- log ---------------------------------------------------------------------------------------------------------
CMD_NAME="-"; NARGS=0; T_START=$(date +%s); M_FREE_KB=""; M_SWAP_MB=""; M_REASON=""
nulljson() { if isnum "$1"; then printf '%s' "$1"; else printf 'null'; fi; }   # ilegível grava null, nunca 0
log_event() { # evento modo rc motivo
  local freegb="null"
  isnum "$M_FREE_KB" && freegb=$(( M_FREE_KB / 1048576 ))
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","event":"%s","mode":"%s","rc":%s,"secs":%s,"reason":"%s","cmd":"%s","nargs":%s,"free_gb":%s,"swap_mb":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$(( $(date +%s) - T_START ))" "$4" "$CMD_NAME" "$NARGS" "$freegb" "$(nulljson "$M_SWAP_MB")" \
    >> "$LOG" 2>/dev/null || say "AVISO: evento '$1' NÃO gravado em $LOG"
}
die() { # rc motivo mensagem — motivo é um token [a-z:_-] (vai para o log)
  say "$3"; log_event refused "${MODE:-local}" "$1" "$2"; exit "$1"
}

# ---- argumentos --------------------------------------------------------------------------------------------------
force_local=0; mode=run; MODE=local
pushes=(); pulls=(); envs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wait-s|--push|--pull|--env) [ $# -ge 2 ] || { say "$1 precisa de um valor"; usage; exit 94; } ;;   # gate:opt-sem-valor
  esac
  case "$1" in
    --local) force_local=1; shift ;;
    --check) mode=check; shift ;;
    --wait-s) WAIT_S="${2:-}"; shift 2 ;;
    --push) pushes+=("${2:-}"); shift 2 ;;
    --pull) pulls+=("${2:-}"); shift 2 ;;
    --env) envs+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) say "opção desconhecida: $1"; usage; exit 94 ;;
    *) break ;;
  esac
done

for v in MIN_FREE_GB MAX_SWAP_MB WAIT_S RUN_TIMEOUT KILL_GRACE_S LOCK_ORPHAN_S NICE; do
  isnum "${!v}" || { say "configuração inválida: $v='${!v}' não é inteiro >= 0"; exit 93; }
done
printf '%s' "$POLL_S" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && [ "$(printf '%s' "$POLL_S" | tr -d '0.')" != "" ] \
  || { say "configuração inválida: REA_RUN_POLL_S='$POLL_S' (número > 0)"; exit 93; }
[ "$RUN_TIMEOUT" -ge 1 ] || { say "configuração inválida: REA_RUN_TIMEOUT_S=0 mataria o comando na hora (use >= 1)"; exit 93; }

# ---- leitura da máquina ------------------------------------------------------------------------------------------
# 0 = há folga · 92 = recusa (M_REASON diz o quê) · 93 = não consegui ler (M_REASON = ilegivel:*)
machine_check() {
  local out kb n need_kb
  M_FREE_KB=""; M_SWAP_MB=""; M_REASON=""
  out=$("$DF_BIN" -Pk "$DF_PATH" 2>/dev/null) || { M_REASON="ilegivel:disco"; return 93; }
  kb=$(printf '%s\n' "$out" | awk 'NR==2{print $4}')
  isnum "$kb" || { M_REASON="ilegivel:disco"; return 93; }                                    # gate:ilegivel-disco
  M_FREE_KB=$kb
  out=$("$SYSCTL_BIN" -n vm.swapusage 2>/dev/null) || { M_REASON="ilegivel:swap"; return 93; }
  n=$(printf '%s' "$out" | awk '{ for (i = 1; i < NF; i++) if ($i == "used" && $(i+1) == "=") v = $(i+2)
        if (v ~ /^[0-9]+(\.[0-9]+)?[KMG]$/) { u = substr(v, length(v)); x = substr(v, 1, length(v) - 1) + 0
          if (u == "G") x *= 1024; else if (u == "K") x /= 1024; printf "%d", x } }')
  isnum "$n" || { M_REASON="ilegivel:swap"; return 93; }                                      # gate:ilegivel-swap
  M_SWAP_MB=$n
  need_kb=$(( MIN_FREE_GB * 1048576 ))
  [ "$M_FREE_KB" -lt "$need_kb" ] && M_REASON="disco-baixo"                                    # gate:disk
  [ "$M_SWAP_MB" -gt "$MAX_SWAP_MB" ] && M_REASON="${M_REASON:+$M_REASON+}swap-alto"          # gate:swap
  [ -z "$M_REASON" ] && return 0
  return 92
}
machine_msg() { printf 'disco livre %s GB (mínimo %s) · swap usado %s MB (máximo %s)' \
  "$(if isnum "$M_FREE_KB"; then awk -v k="$M_FREE_KB" 'BEGIN{printf "%.1f", k/1048576}'; else printf '?'; fi)" "$MIN_FREE_GB" \
  "${M_SWAP_MB:-?}" "$MAX_SWAP_MB"; }

self_chain() { # este processo e seus ancestrais: a linha de comando deles pode conter 'bin/rea ' sem ser outro rea
  local p=$$ out="" i=0
  while isnum "$p" && [ "$p" -gt 1 ] && [ $i -lt 64 ]; do out="$out $p"; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$(( i + 1 )); done
  printf '%s' "$out"
}
OTHERS=""
others_check() { # 0 = nenhum outro rea · 1 = há outro (OTHERS) · 2 = não consegui olhar
  local out rc p chain
  OTHERS=""
  out=$("$PGREP_BIN" -f "$PGREP_PATTERN" 2>/dev/null); rc=$?
  case $rc in 0) ;; 1) return 0 ;; *) return 2 ;; esac                                         # gate:ilegivel-pgrep
  [ -n "$out" ] || return 2   # rc 0 diz "achei", saída vazia diz "não achei": incoerente = não sei
  chain=" $(self_chain) "                                                                      # gate:self-chain
  for p in $out; do
    isnum "$p" || return 2
    case "$chain" in *" $p "*) ;; *) OTHERS="$OTHERS $p" ;; esac
  done
  [ -z "$OTHERS" ] && return 0
  return 1
}

if [ "$mode" = check ]; then
  machine_check; mrc=$?
  others_check; orc=$?
  printf 'rea-run: %s · outro rea: %s\n' "$(machine_msg)" "$( [ $orc -eq 0 ] && echo nenhum || { [ $orc -eq 1 ] && echo "sim (pid$OTHERS)" || echo 'ilegível'; } )"
  [ $mrc -eq 93 ] && { say "não consegui ler: $M_REASON"; exit 93; }
  [ $orc -eq 2 ] && { say "não consegui ler: pgrep"; exit 93; }
  [ $mrc -ne 0 ] && { say "RECUSADO: $M_REASON"; exit 92; }
  [ $orc -eq 1 ] && { say "RECUSADO: outro rea rodando"; exit 92; }
  exit 0
fi

[ $# -gt 0 ] || { say "faltou o comando (use -- <comando>)"; usage; exit 94; }
CMD_NAME=$(printf '%s' "$(basename -- "$1")" | tr -c 'A-Za-z0-9._-' '_'); NARGS=$(( $# - 1 ))
for p in "${pushes[@]+"${pushes[@]}"}"; do
  [ -n "$p" ] && [ -e "$p" ] || { say "--push '$p' não existe"; exit 94; }
done
for pl in "${pulls[@]+"${pulls[@]}"}"; do
  rel=${pl%%:*}; dest=${pl#*:}
  [ "$rel" != "$pl" ] && [ -n "$rel" ] && [ -n "$dest" ] || { say "--pull '$pl' precisa ser REL:LOCAL"; exit 94; }
  case "$rel" in /*|..|../*|*/..|*/../*) say "--pull '$rel': use caminho relativo ao scratch, sem '..'"; exit 94 ;; esac
done
for kv in "${envs[@]+"${envs[@]}"}"; do
  case "$kv" in [A-Za-z_]*=*) ;; *) say "--env '$kv' precisa ser K=V"; exit 94 ;; esac
  case "${kv%%=*}" in *[!A-Za-z0-9_]*) say "--env '$kv': nome inválido"; exit 94 ;; esac
done

# ---- caminho 1: MBP ------------------------------------------------------------------------------------------------
if [ $force_local -eq 0 ] && [ ! -x "$MBP_RUN" ]; then
  say "mbp-run.sh ausente ou sem permissão de execução ($MBP_RUN) — rodando no mini"; log_event fallback mbp 0 "mbp-run-ausente"
fi
if [ $force_local -eq 0 ] && [ -x "$MBP_RUN" ]; then
  margs=(--exec)
  for p in "${pushes[@]+"${pushes[@]}"}"; do margs+=(--push "$p"); done
  for pl in "${pulls[@]+"${pulls[@]}"}"; do margs+=(--pull "$pl"); done
  for kv in "${envs[@]+"${envs[@]}"}"; do margs+=(--env "$kv"); done
  "$MBP_RUN" "${margs[@]}" -- "$@"; rc=$?
  case $rc in
    96|97|98|99) say "MBP indisponível (mbp-run rc=$rc) — rodando no mini"; log_event fallback mbp "$rc" "mbp-rc-$rc" ;;   # gate:fallback
    *) MODE=mbp; log_event ran mbp "$rc" "-"; exit $rc ;;
  esac
fi
MODE=local

# ---- caminho 2: mini -----------------------------------------------------------------------------------------------
DEADLINE=$(( $(date +%s) + WAIT_S ))
LOCK_HELD=0; SCR=""; CHILD=""; WD=""; SIGRC=""

alive() { local s; s=$(ps -o state= -p "$1" 2>/dev/null); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }   # vivo e não-zumbi
tree_pids() { local c; printf '%s\n' "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$c"; done; }
stop_tree() { # TERM na árvore, espera KILL_GRACE_S, KILL no que sobrou
  local pids p i
  pids=$(tree_pids "$1")
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  i=0; while [ $i -lt $(( KILL_GRACE_S * 5 )) ]; do
    local any=0; for p in $pids; do alive "$p" && any=1; done
    [ $any -eq 0 ] && return 0
    sleep 0.2; i=$(( i + 1 ))
  done
  for p in $pids; do alive "$p" && kill -KILL "$p" 2>/dev/null; done
  return 0
}

rm_scratch() { # só remove diretório run.* DENTRO da raiz de scratch, e nunca por symlink
  local d=$1 real root
  [ -e "$d" ] || [ -L "$d" ] || return 0
  [ ! -L "$d" ] || { say "AVISO: $d é symlink — NÃO removido"; return 1; }
  root=$(cd "$SCRATCH_ROOT" 2>/dev/null && pwd -P) || { say "AVISO: raiz $SCRATCH_ROOT ilegível — $d NÃO removido"; return 1; }
  real=$(cd "$d" 2>/dev/null && pwd -P) || { say "AVISO: $d ilegível — NÃO removido"; return 1; }
  case "$real" in "$root"/run.*) ;; *) say "AVISO: $real fora de $root/run.* — NÃO removido"; return 1 ;; esac
  chmod -R u+w "$real" 2>/dev/null
  find "$real" -depth -delete 2>/dev/null                                                       # gate:cleanup
  if [ -e "$real" ]; then say "AVISO: scratch $real NÃO foi apagado por inteiro"; return 1; fi
  return 0
}

owner_field() { sed -n "${1}p" "$LOCK_DIR/owner" 2>/dev/null; }
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//'; }
release_lock() {
  [ $LOCK_HELD -eq 1 ] || return 0
  LOCK_HELD=0
  [ "$(owner_field 1)" = "$$" ] || { say "AVISO: a trava já não é minha — não solto"; return 0; }
  find "$LOCK_DIR" -mindepth 1 -delete 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null \
    || say "AVISO: trava $LOCK_DIR NÃO foi solta"
}
cleanup() {
  [ -n "$CHILD" ] && stop_tree "$CHILD"
  [ -n "$WD" ] && stop_tree "$WD"
  CHILD=""; WD=""
  if [ -n "$SCR" ]; then rm_scratch "$SCR" || log_event cleanup-failed local 0 "scratch-nao-apagado"; SCR=""; fi
  release_lock
}
on_signal() { say "recebi SIG$1 — encerrando o comando e limpando"; SIGRC=$(( 128 + $2 )); exit "$SIGRC"; }
trap cleanup EXIT   # gate:exit-trap — roda também quando o bash morre por sinal; os 3 traps abaixo só dão a mensagem e o rc 128+n
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM
trap 'on_signal HUP 1' HUP

lock_state() { # stale | live | unknown  — quem segura a trava agora
  local pid started cur age
  pid=$(owner_field 1); started=$(owner_field 3)
  if ! isnum "$pid" || [ -z "$started" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$age" -gt "$LOCK_ORPHAN_S" ] 2>/dev/null && [ "$age" -lt 1000000000 ] && { echo stale; return; }
    echo unknown; return
  fi
  cur=$(proc_start "$pid")
  if [ -n "$cur" ]; then [ "$cur" = "$started" ] && echo live || echo stale; return; fi   # gate:lock-live — outro início = pid reaproveitado
  kill -0 "$pid" 2>/dev/null && { echo live; return; }                                    # ps não viu mas o pid responde
  echo stale
}
acquire_lock() {
  local last_msg=0 st now tmp me_start
  me_start=$(proc_start $$)   # sem a hora de início não há como provar que o dono segue vivo: a trava seria reaped com a gente dentro
  [ -n "$me_start" ] || die 93 "ilegivel:ps" "não consegui ler a hora de início deste processo (ps) — não pego a trava às cegas"
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || die 93 "trava-nao-criavel" "não consigo criar $(dirname "$LOCK_DIR")"
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then                                                      # gate:lock
      tmp="$LOCK_DIR/owner.tmp"
      { printf '%s\n%s\n%s\n' "$$" "$(date +%s)" "$me_start" > "$tmp" && mv "$tmp" "$LOCK_DIR/owner"; } 2>/dev/null \
        || { find "$LOCK_DIR" -mindepth 1 -delete 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null
             die 93 "trava-sem-dono" "não consegui gravar o dono da trava em $LOCK_DIR"; }
      LOCK_HELD=1; return 0
    fi
    [ -d "$LOCK_DIR" ] || die 93 "trava-nao-criavel" "não consigo criar a trava $LOCK_DIR"
    st=$(lock_state)
    if [ "$st" = stale ]; then
      tmp="$LOCK_DIR.stale.$$"
      if mv "$LOCK_DIR" "$tmp" 2>/dev/null; then
        find "$tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$tmp" 2>/dev/null
        say "trava órfã removida (dono morto ou pid reaproveitado)"; continue
      fi
    fi
    now=$(date +%s)
    [ "$now" -ge "$DEADLINE" ] && die 91 "trava-ocupada" "esperei ${WAIT_S}s e a trava segue com pid $(owner_field 1) — tente depois"
    if [ $(( now - last_msg )) -ge 60 ]; then say "aguardando a trava (dono pid $(owner_field 1), desde $(owner_field 2))"; last_msg=$now; fi
    sleep "$POLL_S"
  done
}
wait_others() {
  local last_msg=0 now orc
  while :; do
    others_check; orc=$?
    [ $orc -eq 0 ] && return 0
    [ $orc -eq 2 ] && die 93 "ilegivel:pgrep" "não consegui olhar se há outro rea (pgrep falhou)"
    now=$(date +%s)
    [ "$now" -ge "$DEADLINE" ] && die 91 "outro-rea" "esperei ${WAIT_S}s e há outro rea rodando (pid$OTHERS) — tente depois"
    if [ $(( now - last_msg )) -ge 60 ]; then say "aguardando outro rea terminar (pid$OTHERS)"; last_msg=$now; fi
    sleep "$POLL_S"
  done
}
refuse_machine() { # $1 = rc de machine_check
  if [ "$1" -eq 93 ]; then die 93 "$M_REASON" "não consegui ler a máquina ($M_REASON) — não rodo às cegas"; fi
  die 92 "$M_REASON" "RECUSADO ($M_REASON): $(machine_msg) — libere espaço/swap e tente de novo"
}

machine_check; mrc=$?; [ $mrc -eq 0 ] || refuse_machine $mrc
acquire_lock
wait_others
machine_check; mrc=$?; [ $mrc -eq 0 ] || refuse_machine $mrc

mkdir -p "$SCRATCH_ROOT" 2>/dev/null && chmod 700 "$SCRATCH_ROOT" 2>/dev/null || die 93 "scratch-nao-criavel" "não consigo criar $SCRATCH_ROOT"
for old in "$SCRATCH_ROOT"/run.*; do   # sob a trava ninguém mais cria run.*: o que existe é de uma execução que morreu
  [ -e "$old" ] || [ -L "$old" ] || continue
  say "scratch órfão $old — apagando"; rm_scratch "$old" || log_event cleanup-failed local 0 "orfao-nao-apagado"
done
SCR=$(mktemp -d "$SCRATCH_ROOT/run.XXXXXX") || die 93 "scratch-nao-criavel" "mktemp falhou em $SCRATCH_ROOT"
if [ ${#pushes[@]} -gt 0 ]; then
  mkdir "$SCR/in" || die 93 "scratch-nao-criavel" "não consegui criar $SCR/in"
  for p in "${pushes[@]}"; do cp -R -- "$p" "$SCR/in/" || die 93 "push-falhou" "push de $p falhou"; done
fi

( cd "$SCR" && export REA_RUN_SCRATCH="$SCR" REA_RUN_MODE=local && exec env ${envs[@]+"${envs[@]}"} nice -n "$NICE" "$@" ) &
CHILD=$!
( left=$RUN_TIMEOUT
  while [ "$left" -gt 0 ]; do
    step=$(( left < 30 ? left : 30 )); sleep "$step"
    kill -0 "$$" 2>/dev/null || exit 0   # o wrapper morreu (SIGKILL): ninguém limpa, e o pid de CHILD pode já ser de outro processo
    left=$(( left - step ))
  done
  [ "$(ps -o ppid= -p "$CHILD" 2>/dev/null | tr -d ' ')" = "$$" ] || exit 0   # CHILD já saiu, ou o pid foi reaproveitado
  : > "$LOCK_DIR/timeout"; stop_tree "$CHILD" ) &                                                 # gate:timeout
WD=$!
RC=0
{ wait "$CHILD"; RC=$?; } 2>/dev/null
CHILD=""
stop_tree "$WD"; { wait "$WD"; } 2>/dev/null; WD=""
if [ -f "$LOCK_DIR/timeout" ]; then RC=124; say "timeout de ${RUN_TIMEOUT}s — comando encerrado"; fi

PULL_FAILED=""
for pl in "${pulls[@]+"${pulls[@]}"}"; do
  rel=${pl%%:*}; dest=${pl#*:}
  cp -R -- "$SCR/$rel" "$dest" 2>/dev/null || { say "pull de '$rel' falhou — o resultado NÃO chegou em '$dest'"; PULL_FAILED="$PULL_FAILED $rel"; }
done

if [ -n "$PULL_FAILED" ]; then
  log_event ran local "$RC" "pull-falhou"
  [ "$RC" -eq 0 ] && RC=93   # o comando saiu 0 mas o que o chamador pediu de volta não veio: rc 0 diria que veio
  exit $RC
fi
log_event ran local "$RC" "-"
exit $RC
