#!/bin/bash
# hqswap.sh — troca do hq do Dolt pela cópia limpa (dolt gc --full) feita no nó Hetzner.
#
# ## Contents
# - Uso · Modos · O que faz (passos do runbook) · Saídas
#
# Runbook: docs/runbooks/hq-gc-hetzner-swap.md (ga-2895yv.1.1.2/.1.1.3). Este script é a
# janela inteira, passos 2–14 (o 1, pré-condições, é do operador). Em falha DEPOIS do
# irreversível a cidade fica suspensa de propósito. Rode numa sessão tmux própria, NUNCA de dentro de uma sessão do gc:
#   tmux new-session -d -s hqswap 'bash scripts/hqswap.sh run 2>&1 | tee -a .hqswap/hqswap.log'
#
# Modos:
#   run        produção (exige HQSWAP_CONFIRM=sim-producao)
#   rehearsal  Dolt descartável: tudo vem de variáveis HQSWAP_* (C, D, R, NODE_DIR, MBP_DIR,
#              LIFECYCLE); pula launchctl e gc suspend/resume.
#
# Saídas: 0 trocado, conferido e cidade retomada; 10 abortado ANTES do irreversível (mini
# intacto, Dolt religado, cidade retomada); 20 falhou DEPOIS do irreversível (Dolt fica PARADO e travado: voltar atrás B do
# runbook, à mão); 2 uso errado.
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
  run) [ "${HQSWAP_CONFIRM:-}" = "sim-producao" ] || { echo "run exige HQSWAP_CONFIRM=sim-producao" >&2; exit 2; } ;;
  rehearsal) ;;
  *) echo "uso: hqswap.sh run|rehearsal" >&2; exit 2 ;;
esac

C="${HQSWAP_C:-/Users/athos/gt/.gascity-gastown-hq}"
D="${HQSWAP_D:-$C/.beads/dolt}"
R="${HQSWAP_R:-$C/.gc/runtime/packs/dolt}"
X="${HQSWAP_X:-$C/.hqswap}"
NODE="${HQSWAP_NODE:-hetzner-teste}"
NODE_DIR="${HQSWAP_NODE_DIR:-hqgc/seed/hq}"          # relativo ao home do nó
NODE_DOLT="${HQSWAP_NODE_DOLT:-hqgc/bin/dolt}"
MBP="${HQSWAP_MBP:-athoss-macbook-pro.local}"
MBP_DIR="${HQSWAP_MBP_DIR:-hqswap/hq.old}"
LIFECYCLE="${HQSWAP_LIFECYCLE:-$C/.gc/system/packs/bd/assets/scripts/gc-beads-bd.sh}"
PORT="${HQSWAP_PORT:-52756}"
DB=hq
RELEASE="$X/release"
HOLDER_PID="$X/holder.pid"
VERSIONED="${HQSWAP_VERSIONED:-issues comments labels dependencies}"
IGNORED="${HQSWAP_IGNORED:-events wisps wisp_labels wisp_events wisp_comments wisp_dependencies local_metadata leases}"
LAUNCHD_FREEZE="com.gastown.dolt-server com.gascity.supervisor"
WATCHDOGS="com.gascity.dolt-hang-watchdog com.gascity.dolt-disk-floor-guard com.gascity.dolt-latency-alarm"
HALT="$C/.gc/logs/.dolt-compact-routine.HALT"

mkdir -p "$X"
unset GC_DOLT_PORT
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
notify_() { command -v notify >/dev/null 2>&1 && [ "$MODE" = run ] && notify -t 'hqswap' -p 4 "$1" >/dev/null 2>&1; true; }
IRREVERSIBLE=0
die() {
  log "FALHA: $*"
  touch "$X/stop-watch"
  if [ "$IRREVERSIBLE" = 1 ]; then
    log "depois do irreversível: Dolt fica PARADO e travado. Voltar atrás B do runbook, à mão."
    notify_ "hqswap FALHOU depois da troca: $* — Dolt parado, ver $X/hqswap.log"
    exit 20
  fi
  log "antes do irreversível: religando (voltar atrás A)"
  unfreeze_launchd
  release_holder
  lifecycle start || log "AVISO: start falhou — subir à mão"
  finish
  notify_ "hqswap abortado antes da troca: $* — mini intacto"
  exit 10
}
lifecycle() {
  if [ "$MODE" = rehearsal ]; then
    env -i PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
      GC_CITY_PATH="$C" GC_PACK_STATE_DIR="$R" GC_DOLT_DATA_DIR="$D" \
      GC_DOLT_LOG_FILE="$R/dolt.log" GC_DOLT_STATE_FILE="$R/dolt-provider-state.json" \
      GC_DOLT_PID_FILE="$R/dolt.pid" GC_DOLT_LOCK_FILE="$R/dolt.lock" \
      GC_DOLT_CONFIG_FILE="$R/dolt-config.yaml" GC_DOLT_PORT="$PORT" \
      /bin/sh "$LIFECYCLE" "$1"
  else
    GC_CITY_PATH="$C" "$LIFECYCLE" "$1"
  fi
}
freeze_launchd() {
  [ "$MODE" = run ] || return 0
  for l in $LAUNCHD_FREEZE; do launchctl disable "gui/$(id -u)/$l" || return 1; done
}
unfreeze_launchd() {
  [ "$MODE" = run ] || return 0
  for l in $LAUNCHD_FREEZE; do launchctl enable "gui/$(id -u)/$l" || log "AVISO: enable $l falhou"; done
}
holder_ok() {
  local n
  n=$(lsof "$R/dolt.lock" "$R/recover-managed-bd-trigger.stamp" 2>/dev/null | awk 'NR>1{print $NF}' | sort -u | wc -l)
  [ "$n" -eq 2 ] && [ -s "$HOLDER_PID" ] && kill -0 "$(cat "$HOLDER_PID")" 2>/dev/null
}
release_holder() {
  touch "$RELEASE"
  local i=0
  while [ $i -lt 20 ] && [ -s "$HOLDER_PID" ] && kill -0 "$(cat "$HOLDER_PID")" 2>/dev/null; do sleep 1; i=$((i+1)); done
}
no_dolt_on() {  # nenhum processo dolt com arquivo aberto sob $1
  ! lsof +D "$1" 2>/dev/null | awk 'NR>1{print $1}' | grep -qi '^dolt'
}
node() { ssh -o BatchMode=yes "$NODE" "$@"; }
node_counts() {  # HEAD + contagens da cópia no nó, uma tabela por chamada
  printf 'HEAD %s\n' "$(node "cd $NODE_DIR && ~/$NODE_DOLT sql -r csv -q 'select commit_hash from dolt_log limit 1' 2>&1 | tail -1")"
  for t in $VERSIONED $IGNORED; do
    printf '%s %s\n' "$t" "$(node "cd $NODE_DIR && ~/$NODE_DOLT sql -r csv -q 'select count(*) from \`$t\`' 2>&1 | tail -1")"
  done
}
live_counts() {  # o servidor novo: HEAD da base no histórico + versionadas AS OF a base (estrito); ignoradas (só aviso)
  local head="$1" q
  q() { dolt --host 127.0.0.1 --port "$PORT" --no-tls -u root -p '' --use-db "$DB" sql -r csv -q "$1" 2>&1 | tail -1; }
  printf 'HEAD %s\n' "$( [ "$(q "select count(*) from dolt_log where commit_hash='$head'")" = 1 ] && echo "$head" || echo "AUSENTE:$head")"
  for t in $VERSIONED; do printf '%s %s\n' "$t" "$(q "select count(*) from \`$t\` as of '$head'")"; done
}
live_ignored() { local t; for t in $IGNORED; do printf '%s %s\n' "$t" "$(dolt --host 127.0.0.1 --port "$PORT" --no-tls -u root -p '' --use-db "$DB" sql -r csv -q "select count(*) from \`$t\`" 2>&1 | tail -1)"; done; }
same_content() {  # $1 = destino rsync; vazio = idêntico em conteúdo. Horário de diretório (.d..t) só é registrado
  local out content
  out=$(rsync -a --checksum --delete --dry-run --itemize-changes "$D/$DB/" "$1/" 2>&1) || { log "rsync dry-run falhou: $out"; return 1; }
  content=$(printf '%s\n' "$out" | grep -v '^\.[fd]\.\.t[.]* ' | grep -v '^$')
  [ -n "$out" ] && [ -z "$content" ] && log "só horário (arquivo/diretório) difere em $1: $(printf '%s' "$out" | tr '\n' ' ')"
  [ -z "$content" ] || { log "conteúdo difere em $1: $(printf '%s' "$content" | head -5 | tr '\n' ' ')"; return 1; }
}
mbp_identical() {
  same_content "$MBP:$MBP_DIR" || return 1
  local lf lb rf rb
  lf=$(find "$D/$DB" -type f | wc -l | tr -d ' '); lb=$(find "$D/$DB" -type f -exec stat -f %z {} + | awk '{s+=$1} END{print s}')
  rf=$(ssh "$MBP" "find $MBP_DIR -type f | wc -l" | tr -d ' '); rb=$(ssh "$MBP" "find $MBP_DIR -type f -exec stat -f %z {} + | awk '{s+=\$1} END{print s}'")
  log "MacBook: arquivos $lf/$rf, bytes $lb/$rb"
  [ "$lf" = "$rf" ] && [ "$lb" = "$rb" ]
}
watch_dotdolt() {  # registra cada mudança de entradas em $D/$DB/.dolt (pega quem abre o banco sem lock)
  local prev="" cur=""
  while [ ! -e "$X/stop-watch" ]; do
    cur=$(ls -la "$D/$DB/.dolt" 2>/dev/null | awk 'NR>1{print $1,$5,$6,$7,$8,$9}')
    if [ "$cur" != "$prev" ]; then
      { echo "--- $(date '+%T')"; printf '%s\n' "$cur"; lsof +D "$D/$DB" 2>/dev/null | awk 'NR>1{print $1,$2}' | sort -u; } >> "$X/dotdolt-watch.log"
      prev=$cur
    fi
    sleep 1
  done
}
prep() {  # passos 2-3 do runbook (só em produção)
  [ "$MODE" = run ] || return 0
  touch "$HALT" || return 1
  : > "$X/watchdogs-booted-out.txt"
  for l in $WATCHDOGS; do
    if launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$l" && echo "$l" >> "$X/watchdogs-booted-out.txt"
    fi
  done
  (cd "$C" && gc suspend) || return 1
  sleep 60   # sessões de agente recebem o suspend
}
finish() {  # passos 13-14: gc resume + vigias de volta (o HALT fica, de propósito)
  [ "$MODE" = run ] || return 0
  (cd "$C" && gc resume) || log "AVISO: gc resume falhou — rodar à mão"
  while read -r l; do
    [ -n "$l" ] && { launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$l.plist" || log "AVISO: bootstrap $l falhou"; }
  done < "$X/watchdogs-booted-out.txt"
}

log "=== hqswap $MODE: D=$D X=$X nó=$NODE:$NODE_DIR mbp=$MBP:$MBP_DIR"
[ -d "$D/$DB/.dolt" ] || { log "não achei $D/$DB/.dolt"; exit 2; }
[ ! -e "$X/hq.new" ] && [ ! -e "$X/hq.old" ] || { log "$X/hq.new ou hq.old já existe — limpe antes"; exit 2; }

prep || die "preparação (HALT/vigias/gc suspend) falhou"
log "2-3 preparação ok (HALT, vigias fora: $(tr '\n' ' ' < "$X/watchdogs-booted-out.txt" 2>/dev/null), cidade suspensa)"

# 4. holder
rm -f "$RELEASE" "$HOLDER_PID"
touch "$R/dolt.lock" "$R/recover-managed-bd-trigger.stamp"
flock "$R/dolt.lock" flock "$R/recover-managed-bd-trigger.stamp" \
  sh -c "echo \$\$ > '$HOLDER_PID'; while [ ! -e '$RELEASE' ]; do sleep 2; done" &
for _ in $(seq 1 180); do holder_ok && break; sleep 1; done
holder_ok || die "holder não pegou os 2 locks em 3 min"
log "4 holder ok (pid $(cat "$HOLDER_PID"))"

# 5. parar
lifecycle stop; rc=$?
[ $rc -eq 0 ] || [ $rc -eq 2 ] || die "stop rc=$rc"
for _ in $(seq 1 30); do no_dolt_on "$D/$DB" && break; sleep 1; done
no_dolt_on "$D/$DB" || die "ainda há processo dolt com o hq aberto depois do stop"
log "5 Dolt parado"
rm -f "$X/stop-watch"; watch_dotdolt & WATCH_PID=$!

# 6. travar o launchd (sobrevive a reboot)
freeze_launchd || die "launchctl disable falhou"
log "6 launchd travado"

# 7. cópias em paralelo
holder_ok || die "holder sumiu antes do passo 7"
( rsync -a --delete --checksum "$D/$DB/" "$NODE:$NODE_DIR/" ) > "$X/rsync-node.log" 2>&1 &
PN=$!
( ssh "$MBP" "mkdir -p $MBP_DIR" && rsync -a --delete "$D/$DB/" "$MBP:$MBP_DIR/" ) > "$X/rsync-mbp.log" 2>&1 &
PM=$!
wait $PN || die "rsync para o nó falhou ($X/rsync-node.log)"
log "7a nó com a cópia congelada"
wait $PM || die "rsync para o MacBook falhou ($X/rsync-mbp.log)"
log "7b MacBook com a cópia congelada"
same_content "$NODE:$NODE_DIR" || die "cópia do nó não confere com o mini antes do GC"
log "7c nó idêntico ao mini (conteúdo) — o GC roda sobre este estado"

# 8. linha de base no nó (antes do GC)
node_counts > "$X/base.txt" || die "contagem de base no nó falhou"
BASE_HEAD=$(awk '$1=="HEAD"{print $2}' "$X/base.txt")
[ -n "$BASE_HEAD" ] || die "HEAD de base vazio"
grep -qiE 'error|not found' "$X/base.txt" && die "erro nas contagens de base: $(cat "$X/base.txt")"
log "8 base: $(tr '\n' ' ' < "$X/base.txt")"

# 9. GC + contagens + fsck no nó
node "cd $NODE_DIR && ~/$NODE_DOLT gc --full --archive-level=0 --incremental-file-size=1073741824" > "$X/gc.log" 2>&1 \
  || die "dolt gc no nó falhou ($X/gc.log)"
node_counts > "$X/after-gc.txt"
diff -u "$X/base.txt" "$X/after-gc.txt" || die "contagens/HEAD mudaram com o GC"
node "cd $NODE_DIR && ~/$NODE_DOLT fsck" > "$X/fsck.log" 2>&1 || die "fsck sujo ($X/fsck.log)"
log "9 GC ok, contagens iguais, fsck limpo; nó: $(node "du -sh $NODE_DIR" | cut -f1)"

# 10. MacBook bit a bit (e o mini não mudou desde a cópia)
mbp_identical || die "cópia do MacBook não confere"
log "10 MacBook idêntico"

# 11. troca — IRREVERSÍVEL
holder_ok || die "holder sumiu antes do passo 11"
no_dolt_on "$D/$DB" || die "processo dolt abriu o hq antes da troca"
IRREVERSIBLE=1
mv "$D/$DB" "$X/hq.old" || die "mv do hq antigo"
need_kb=$(node "du -sk $NODE_DIR" | cut -f1)
free_kb=$(df -k "$X" | awk 'NR==2{print $4}')
if [ "$free_kb" -lt $((need_kb + 3*1024*1024)) ]; then
  log "11 pouco disco ($((free_kb/1024)) MB livres, novo $((need_kb/1024)) MB): apagando o antigo antes (cópia no MacBook conferida)"
  rm -rf "$X/hq.old" || die "não consegui apagar $X/hq.old"
fi
rsync -a "$NODE:$NODE_DIR/" "$X/hq.new/" > "$X/rsync-back.log" 2>&1 || die "volta do nó falhou"
[ -z "$(rsync -a --checksum --dry-run --itemize-changes "$NODE:$NODE_DIR/" "$X/hq.new/" 2>&1)" ] || die "volta não confere"
[ ! -e "$D/$DB" ] && mv -n "$X/hq.new" "$D/$DB" && test -f "$D/$DB/.dolt/noms/manifest" || die "mv do novo para $D/$DB"
log "11 hq novo no lugar"

# 12. subir e conferir
unfreeze_launchd
release_holder
lifecycle start || die "start falhou"
for _ in $(seq 1 30); do dolt --host 127.0.0.1 --port "$PORT" --no-tls -u root -p '' sql -q 'select 1' >/dev/null 2>&1 && break; sleep 2; done
live_counts "$BASE_HEAD" > "$X/live.txt"
grep -E "^(HEAD|$(echo $VERSIONED | tr ' ' '|')) " "$X/base.txt" | diff -u - "$X/live.txt" \
  || die "servidor novo difere da base nas tabelas versionadas (Dolt está NO AR com o hq novo; hq antigo no MacBook)"
live_ignored > "$X/live-ignored.txt"
grep -vE "^(HEAD|$(echo $VERSIONED | tr ' ' '|')) " "$X/base.txt" | diff -u - "$X/live-ignored.txt" \
  && log "12 tabelas ignoradas iguais à base" || log "AVISO: tabelas ignoradas diferem da base (pode ser gravação nova depois do start) — conferir $X/live-ignored.txt"
log "12 servidor novo conferido; hq agora $(du -sh "$D/$DB" | cut -f1)"
[ -d "$X/hq.old" ] && log "hq.old ainda em $X/hq.old (apagar depois de 24 h ou quando o disco pedir)"
touch "$X/stop-watch"
finish
log "13-14 cidade retomada, vigias de volta (HALT da rotina de compactação FICA)"
notify_ "hqswap OK: hq agora $(du -sh "$D/$DB" | cut -f1), cidade retomada."
log "=== fim OK"
exit 0
