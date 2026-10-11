#!/usr/bin/env bash
# mbp-run.sh — roda testes dirigidos (pytest) ou um comando pesado (rea/jadx/...) no MacBook Pro.
#
# Contents
#   Por quê · Uso · Códigos de saída · Toggle · Como funciona · Segurança
#
# POR QUÊ (Athos 11/10): o mini vive com load 40-60 e swap alto; os MESMOS 231 testes de lot_groups levam
#   161 s no mini e 5,3 s no MBP. O MBP (16 GB, 12 CPUs) vira nó de capacidade, com chave de ligar/desligar.
#
# USO
#   mbp-run.sh [--repo wa|ps] [--dir <worktree>] -- <args do pytest>        # ex.: -- tests/test_x.py -q
#        (ps = checkout de código do property_scrapers em ~/.property-scrapers/runtime/main, não o rig-contêiner)
#   mbp-run.sh --exec [--push P]... [--pull REL:LOCAL]... [--env K=V]... [--keep] -- <comando> [args]
#        (REA/APK; o comando roda em ~/gt-remote/exec/<slot>; --push copia P para ./in/; --pull traz REL de volta;
#         o scratch é APAGADO ao fim (capturas de REA nunca ficam) salvo --keep. Para redirecionar saída use
#         `-- sh -c 'rea ... > out.json'`.)
#   mbp-run.sh --seed wa|ps          # (re)semeia a árvore-base e o site-packages do MBP (com checagem de hash)
#   mbp-run.sh --check               # imprime a saúde do MBP (preflight) e sai
#
# CÓDIGOS DE SAÍDA — qualquer 96..99 significa "rode local": quem chama NUNCA trata isso como falha de teste.
#   0..95  código do pytest/comando remoto (propagado)
#   99  offload desligado (falta $CITY/.gc/mbp-offload.on)
#   98  MBP indisponível/sem saúde (ssh > 5 s, RAM livre < 3 GB, swap usado >= 5 GB, bateria < 40% sem tomada,
#       ou ssh caiu no meio da execução)
#   97  configuração (uso errado, árvore-base ausente no MBP -> rode --seed)
#   96  3 slots ocupados
#
# TOGGLE: scripts/mbp-offload.sh on|off|status (arquivo-bandeira; o botão do painel é a bead de painel).
# COMO FUNCIONA: preflight (1 ssh) -> slot (mkdir atômico em ~/gt-remote/slots/N, dono=host:pid:epoch, reaping de
#   dono morto/idade) -> espelho por slot (~/gt-remote/mirror/<repo>-N, clone APFS da base na 1ª vez) -> rsync do
#   worktree do chamador -> pytest no venv do MBP com nice -> stream -> libera o slot -> log jsonl.
# SEGURANÇA: só testes dirigidos (nunca a suíte inteira). Não envia .git, venv, shared/data, *.db. Nenhum segredo
#   viaja no comando; o MBP usa o mesmo `secret`/Bitwarden do mini quando a tarefa precisar (decisão do Athos).
set -o pipefail

CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
MBP_HOST=${MBP_HOST:-athos@athoss-macbook-pro.local}
FLAG="$CITY/.gc/mbp-offload.on"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
MIN_AVAIL_MB=${MBP_MIN_AVAIL_MB:-3072}
MAX_SWAP_MB=${MBP_MAX_SWAP_MB:-5120}
MIN_BATT=${MBP_MIN_BATT:-40}
MAX_SLOTS=${MBP_MAX_SLOTS:-3}
SLOT_MAX_AGE=${MBP_SLOT_MAX_AGE_S:-14400}
RUN_TIMEOUT=${MBP_RUN_TIMEOUT_S:-3600}
SSH_BIN=${MBP_SSH:-ssh}
RSYNC_BIN=${MBP_RSYNC:-rsync}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=/tmp/mbp-cm-%C -o ControlPersist=60"
ME="$(hostname -s 2>/dev/null || echo mini)"
OWNER="$ME:$$:$(date +%s)"

EXCLUDES=(--exclude .git --exclude venv --exclude .venv --exclude crew --exclude refinery --exclude .worktrees
  --exclude shared/data --exclude __pycache__ --exclude node_modules --exclude '*.db' --exclude '*.db-wal'
  --exclude '*.db-shm' --exclude .pytest_cache
  --exclude /.beads --exclude /.repo.git --exclude /.viewer-deploy-clone --exclude /.playwright-mcp --exclude /.gc
  --exclude /.claude --exclude /scratchpad --exclude /logs --exclude '/shared/logs*' --exclude '/shared/*backup*')

say() { printf 'mbp-run: %s\n' "$*" >&2; }
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2; }

repo=""; dir="$PWD"; mode=pytest; seed_repo=""
pushes=(); pulls=(); envs=(); keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    --exec) mode=exec; shift ;;
    --seed) mode=seed; seed_repo="${2:-}"; shift 2 ;;
    --check) mode=check; shift ;;
    --push) pushes+=("${2:-}"); shift 2 ;;
    --pull) pulls+=("${2:-}"); shift 2 ;;
    --env) envs+=("${2:-}"); shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

base_of() { case "$1" in wa) echo whatsapp_automation ;; ps) echo property_scrapers ;; esac; }
venv_of() { case "$1" in wa) echo venv ;; ps) echo venv-ps ;; esac; }
local_root_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation ;; ps) echo /Users/athos/.property-scrapers/runtime/main ;; esac; }
local_venv_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation/venv ;; ps) echo /Users/athos/.property-scrapers/runtime/main/venv ;; esac; }

rssh() { "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s; }

log_run() { # repo mode slot rc secs
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","repo":"%s","mode":"%s","slot":"%s","rc":%s,"secs":%s,"nargs":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$(( $# - 5 ))" >> "$LOG" 2>/dev/null || true
}

# ---- preflight: UMA chamada ssh; imprime pares k=v -------------------------------------------------------------
preflight() {
  local out rc
  out=$(rssh <<'EOF' 2>/dev/null
# MBP:PREFLIGHT
ps=$(pagesize 2>/dev/null || echo 16384)
vm=$(vm_stat 2>/dev/null)
g() { echo "$vm" | awk -v k="$1" '$0 ~ k {gsub(/[^0-9]/,"",$NF); print $NF; exit}'; }
free=$(g "Pages free"); inact=$(g "Pages inactive"); spec=$(g "Pages speculative")
echo "avail_mb=$(( (${free:-0}+${inact:-0}+${spec:-0}) * ps / 1048576 ))"
echo "swap_mb=$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub(/M/,"",$6); print int($6)}')"
b=$(pmset -g batt 2>/dev/null)
case "$b" in *"AC Power"*) echo "power=ac" ;; *) echo "power=battery" ;; esac
echo "batt=$(echo "$b" | grep -o '[0-9]*%' | head -1 | tr -d '%')"
echo "load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
EOF
  ); rc=$?
  [ $rc -eq 0 ] && [ -n "$out" ] || { say "MBP inalcançável (ssh rc=$rc) — rode local"; return 98; }
  PF="$out"
  local avail swap power batt
  avail=$(echo "$out" | sed -n 's/^avail_mb=//p'); swap=$(echo "$out" | sed -n 's/^swap_mb=//p')
  power=$(echo "$out" | sed -n 's/^power=//p'); batt=$(echo "$out" | sed -n 's/^batt=//p')
  [ "${avail:-0}" -ge "$MIN_AVAIL_MB" ] || { say "MBP sem RAM livre (${avail:-?} MB < $MIN_AVAIL_MB) — rode local"; return 98; }
  [ "${swap:-99999}" -lt "$MAX_SWAP_MB" ] || { say "MBP com swap alto (${swap:-?} MB >= $MAX_SWAP_MB) — rode local"; return 98; }
  if [ "$power" != "ac" ] && [ "${batt:-0}" -le "$MIN_BATT" ]; then
    say "MBP na bateria (${batt:-?}% <= $MIN_BATT%) — rode local"; return 98
  fi
  return 0
}

# ---- slots ------------------------------------------------------------------------------------------------------
SLOT=""
acquire_once() {
  rssh <<EOF 2>/dev/null
# MBP:SLOT_ACQUIRE
S="\$HOME/gt-remote/slots"; mkdir -p "\$S"
n=1
while [ \$n -le $MAX_SLOTS ]; do
  if mkdir "\$S/\$n" 2>/dev/null; then printf '%s\n' '$OWNER' > "\$S/\$n/owner"; echo "SLOT=\$n"; exit 0; fi
  n=\$((n+1))
done
n=1
while [ \$n -le $MAX_SLOTS ]; do
  echo "BUSY \$n \$(cat "\$S/\$n/owner" 2>/dev/null | tr -d ' ') \$(stat -f %m "\$S/\$n" 2>/dev/null)"
  n=\$((n+1))
done
echo FULL; exit 3
EOF
}
force_release() { # n
  rssh <<EOF >/dev/null 2>&1
# MBP:SLOT_REAP
S="\$HOME/gt-remote/slots/$1"
rm -f "\$S/owner"; rmdir "\$S" 2>/dev/null; true
EOF
}
acquire() {
  local out rc now line n owner mt h p e
  for attempt in 1 2; do
    out=$(acquire_once); rc=$?
    SLOT=$(echo "$out" | sed -n 's/^SLOT=//p' | head -1)
    [ -n "$SLOT" ] && return 0
    [ $rc -eq 255 ] && { say "ssh caiu ao pegar slot"; return 98; }
    [ $attempt -eq 2 ] && break
    now=$(date +%s); reaped=0
    while IFS= read -r line; do
      case "$line" in BUSY*) ;; *) continue ;; esac
      set -- $line; n=$2; owner=${3:-}; mt=${4:-0}
      h=${owner%%:*}; p=${owner#*:}; p=${p%%:*}; e=${owner##*:}
      stale=0
      if [ -z "$owner" ]; then [ $((now - ${mt:-0})) -gt 60 ] && stale=1
      else
        [ "$h" = "$ME" ] && [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && stale=1
        case "$e" in ''|*[!0-9]*) ;; *) [ $((now - e)) -gt "$SLOT_MAX_AGE" ] && stale=1 ;; esac
      fi
      if [ $stale -eq 1 ]; then say "slot $n morto (dono=$owner) — liberando"; force_release "$n"; reaped=1; fi
    done <<<"$out"
    [ $reaped -eq 1 ] || break
  done
  say "todos os $MAX_SLOTS slots do MBP ocupados — rode local"; return 96
}
release() {
  [ -n "$SLOT" ] || return 0
  rssh <<EOF >/dev/null 2>&1
# MBP:SLOT_RELEASE
S="\$HOME/gt-remote/slots/$SLOT"
if grep -q '$OWNER' "\$S/owner" 2>/dev/null; then rm -f "\$S/owner"; rmdir "\$S" 2>/dev/null; fi
true
EOF
  SLOT=""
}
cleanup() { release; [ -n "${TMPOUT:-}" ] && rm -f "$TMPOUT"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---- seed / check -----------------------------------------------------------------------------------------------
if [ "$mode" = check ]; then
  preflight; rc=$?
  printf '%s\n' "${PF:-}"; echo "offload_flag=$([ -f "$FLAG" ] && echo on || echo off)"
  exit $rc
fi

if [ "$mode" = seed ]; then
  case "$seed_repo" in wa|ps) ;; *) say "uso: --seed wa|ps"; exit 97 ;; esac
  preflight || exit $?
  root=$(local_root_of "$seed_repo"); base=$(base_of "$seed_repo"); lv=$(local_venv_of "$seed_repo"); rv=$(venv_of "$seed_repo")
  say "semeando ~/gt-remote/$base a partir de $root"
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p gt-remote/$base gt-remote/mirror gt-remote/slots" || exit 98
  "$RSYNC_BIN" -a --delete -e "$SSH_BIN $SSH_OPTS" "${EXCLUDES[@]}" "$root"/ "$MBP_HOST:gt-remote/$base/" || exit 98
  sp=$(ls -d "$lv"/lib/python3.*/site-packages 2>/dev/null | head -1)
  [ -n "$sp" ] || { say "site-packages local não achado em $lv"; exit 97; }
  pyver=$(echo "$sp" | sed -n 's#.*/lib/\(python3\.[0-9]*\)/site-packages#\1#p')
  hash=$(ls "$sp" | grep -E '\.dist-info$' | LC_ALL=C sort | shasum | awk '{print $1}')
  rhash=$("$SSH_BIN" $SSH_OPTS "$MBP_HOST" "cat gt-remote/$rv/.sp-hash 2>/dev/null")
  if [ "$hash" = "$rhash" ]; then say "site-packages do MBP já bate (hash ${hash:0:12})"; exit 0; fi
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "zsh -lc 'test -d gt-remote/$rv || $pyver -m venv gt-remote/$rv'" || { say "venv no MBP falhou ($pyver)"; exit 98; }
  "$RSYNC_BIN" -a --delete --exclude __pycache__ -e "$SSH_BIN $SSH_OPTS" "$sp"/ "$MBP_HOST:gt-remote/$rv/lib/$pyver/site-packages/" || exit 98
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "echo $hash > gt-remote/$rv/.sp-hash"
  say "seed $seed_repo ok (hash $hash)"; exit 0
fi

# ---- caminho normal (pytest | exec) ----------------------------------------------------------------------------
[ -f "$FLAG" ] || { say "offload desligado (falta $FLAG) — rode local"; exit 99; }

if [ "$mode" = pytest ]; then
  if [ -z "$repo" ]; then
    case "$dir" in *whatsapp_automation*) repo=wa ;; *property_scrapers*|*property-scrapers*) repo=ps ;; esac
  fi
  case "$repo" in wa|ps) ;; *) say "não deduzi o repo de '$dir' — use --repo wa|ps"; usage; exit 97 ;; esac
  [ $# -gt 0 ] || { say "faltam os argumentos do pytest (use -- tests/test_x.py)"; exit 97; }
  [ -d "$dir/tests" ] || { say "$dir não tem tests/ — use --dir <worktree>"; exit 97; }
else
  [ $# -gt 0 ] || { say "faltou o comando (use -- <comando>)"; exit 97; }
fi

preflight || exit $?
acquire || exit $?
T0=$(date +%s)
TMPOUT=$(mktemp "${TMPDIR:-/tmp}/mbp-run.XXXXXX")
RC=0
qargs=$(printf '%q ' "$@")

if [ "$mode" = pytest ]; then
  base=$(base_of "$repo"); rv=$(venv_of "$repo"); M="gt-remote/mirror/$repo-$SLOT"
  m=$(rssh <<EOF 2>/dev/null
# MBP:MIRROR
B="\$HOME/gt-remote/$base"; M="\$HOME/$M"
[ -d "\$M" ] && { echo MIRROR_OK; exit 0; }
[ -d "\$B" ] || { echo NOBASE; exit 97; }
mkdir -p "\$HOME/gt-remote/mirror" && cp -cR "\$B" "\$M" && echo MIRROR_SEEDED
EOF
  ); mrc=$?
  case "$m" in
    *NOBASE*) say "base ~/gt-remote/$base ausente no MBP — rode: mbp-run.sh --seed $repo"; exit 97 ;;
    *MIRROR_*) ;;
    *) [ $mrc -eq 255 ] && { say "ssh caiu ao preparar o espelho"; exit 98; }; say "espelho falhou: $m"; exit 98 ;;
  esac
  "$RSYNC_BIN" -a --delete -e "$SSH_BIN $SSH_OPTS" "${EXCLUDES[@]}" "$dir"/ "$MBP_HOST:$M/" >/dev/null 2>&1
  rrc=$?; [ $rrc -eq 0 ] || { say "rsync do worktree falhou (rc=$rrc) — rode local"; exit 98; }
  timeout "$RUN_TIMEOUT" "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s 2>&1 <<EOF | tee "$TMPOUT"
# MBP:RUN
export PATH=/opt/homebrew/bin:\$PATH PYTHONDONTWRITEBYTECODE=1
cd "\$HOME/$M" || exit 97
exec nice -n 10 "\$HOME/gt-remote/$rv/bin/python" -m pytest -p no:cacheprovider $qargs
EOF
  RC=${PIPESTATUS[0]}
  if [ $RC -ne 0 ] && grep -q -E 'shared/data|\.db\b|unable to open database' "$TMPOUT"; then
    say "NOTE: shared/data/ e *.db NÃO são enviados ao MBP; teste que lê esses arquivos falha aqui — rode esse teste local."
  fi
else
  X="gt-remote/exec/$SLOT"
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p $X/in" || { say "ssh caiu ao preparar o scratch"; exit 98; }
  for p in "${pushes[@]+"${pushes[@]}"}"; do
    [ -n "$p" ] || continue
    "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$p" "$MBP_HOST:$X/in/" >/dev/null 2>&1 || { say "push de $p falhou"; exit 98; }
  done
  envline=""
  for kv in "${envs[@]+"${envs[@]}"}"; do [ -n "$kv" ] && envline="$envline $(printf '%q' "$kv")"; done
  timeout "$RUN_TIMEOUT" "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s 2>&1 <<EOF | tee "$TMPOUT"
# MBP:EXEC
export PATH="\$HOME/gt-remote/rea/bin:/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:\$PATH"
export GHIDRA_INSTALL_DIR="\${GHIDRA_INSTALL_DIR:-/opt/homebrew/opt/ghidra/libexec}"
export JAVA_HOME="\${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
cd "\$HOME/$X" || exit 97
exec env$envline nice -n 10 $qargs
EOF
  RC=${PIPESTATUS[0]}
  for pl in "${pulls[@]+"${pulls[@]}"}"; do
    rel=${pl%%:*}; dest=${pl#*:}
    [ -n "$rel" ] && [ -n "$dest" ] || continue
    "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$MBP_HOST:$X/$rel" "$dest" >/dev/null 2>&1 || say "pull de $rel falhou"
  done
  if [ $keep -eq 0 ]; then
    "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "find $X -mindepth 1 -delete" >/dev/null 2>&1 || say "AVISO: scratch $X não foi limpo"
  fi
fi

SECS=$(( $(date +%s) - T0 ))
if [ $RC -eq 255 ]; then say "ssh caiu durante a execução — rode local"; log_run "${repo:-exec}" "$mode" "$SLOT" 255 "$SECS" "$@"; exit 98; fi
if [ $RC -eq 124 ]; then say "timeout de ${RUN_TIMEOUT}s"; fi
log_run "${repo:-exec}" "$mode" "$SLOT" "$RC" "$SECS" "$@"
exit $RC
