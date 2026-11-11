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
#   HQSWAP_FLATTEN=1 (vale nos dois modos): antes do GC, ACHATA o histórico na cópia do nó
#              (ga-1p1i5jr.12) — mesmo dado, hash de cada tabela conferido antes/depois, 1 commit.
#              Perde a "viagem no tempo" do Dolt (decisão do Athos, ga-2895yv); o histórico
#              completo fica na cópia do MacBook (passo 7b, estado de antes do flatten) e no S3.
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
FLATTEN="${HQSWAP_FLATTEN:-0}"
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
flatten_script() {  # imprime o script que roda NO NÓ, dentro de $NODE_DIR, com $1 = binário dolt (ga-1p1i5jr.12)
  # mesmo dado antes/depois (hash de cada tabela), histórico vira raiz + 1 commit, sem branch nem tag que segure o
  # histórico velho (senão o GC não libera nada). Saídas: 0 ok; 3 recusou antes de mexer; 4 mexeu e não confere
  # (a cópia do nó é descartável: o hqswap aborta antes do irreversível, mini intacto)
  # o script chega por stdin (bash -s): o corpo é UMA função, lida inteira antes de rodar, e roda com stdin=/dev/null —
  # senão um dolt que lê stdin comeria o resto do script
  cat <<'FLAT'
flatten_main() {
set -euo pipefail
B="$1"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
q() { "$B" sql -r csv -q "$1" | tail -n +2; }
hashes() { local t h; q "select table_name from information_schema.tables where table_schema = database() and table_type = 'BASE TABLE' order by table_name" > "$tmp/tables"; [ -s "$tmp/tables" ] || return 1
  while IFS= read -r t; do h=$(q "select dolt_hashof_table('$t')") && [ -n "$h" ] || return 1; printf '%s %s\n' "$t" "$h"; done < "$tmp/tables"; }
hashes > "$tmp/before" || { echo "flatten: tabelas ou hash ilegível — nada mexido"; exit 3; }
[ "$("$B" branch --show-current)" = main ] || { echo "flatten: branch atual não é main — nada mexido"; exit 3; }
root=$(q "select commit_hash from dolt_log order by date asc limit 1")
[ -n "$root" ] || { echo "flatten: raiz ilegível — nada mexido"; exit 3; }
tags=$("$B" tag) || { echo "flatten: lista de tags ilegível — nada mexido"; exit 3; }
for b in $("$B" branch | sed 's/^[* ]*//'); do [ "$b" = main ] || "$B" branch -D -f "$b" >/dev/null || exit 4; done
for t in $tags; do "$B" tag -d "$t" >/dev/null || exit 4; done
"$B" reset --soft "$root" >/dev/null || exit 4
"$B" add -A || exit 4
"$B" commit --allow-empty -m "hqswap: flatten do histórico (ga-1p1i5jr.12)" >/dev/null || exit 4
hashes > "$tmp/after" || { echo "flatten: hash ilegível depois"; exit 4; }
diff "$tmp/before" "$tmp/after" || { echo "flatten: hash de tabela mudou"; exit 4; }
n=$(q "select count(*) from dolt_log")
[ "$n" -le 2 ] || { echo "flatten: sobraram $n commits"; exit 4; }
left=$("$B" tag) && [ -z "$left" ] && [ "$("$B" branch | wc -l | tr -d ' ')" = 1 ] || { echo "flatten: sobrou branch ou tag"; exit 4; }
echo "flatten ok: commits=$n tabelas=$(wc -l < "$tmp/before" | tr -d ' ') raiz=$root"
 }
flatten_main "$@" </dev/null
FLAT
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
dotdolt_mtimes() {  # horário em SEGUNDOS de .dolt e .dolt/noms: o ls -la só mostra o minuto, e quem abre o banco some em ~1 s (ga-06wmmp)
  local m
  # falhou/ilegível (qualquer um dos dois diretórios) → "?", nunca um número só nem vazio; o status do stat vem direto da
  # atribuição, sem pipeline (não depende do pipefail de quem chama). stat GNU primeiro, o do macOS como reserva
  m=$(stat -c '%Y' "$D/$DB/.dolt" "$D/$DB/.dolt/noms" 2>/dev/null) || m=""
  [ -n "$m" ] || m=$(stat -f '%m' "$D/$DB/.dolt" "$D/$DB/.dolt/noms" 2>/dev/null) || m=""
  [ -n "$m" ] && m=$(printf '%s' "$m" | tr '\n' ' ')
  printf 'mtime(.dolt noms) %s\n' "${m:-?}"
}
watch_dotdolt() {  # registra cada mudança de entradas em $D/$DB/.dolt (pega quem abre o banco sem lock)
  local prev="" cur=""
  while [ ! -e "$X/stop-watch" ]; do
    cur=$(ls -la "$D/$DB/.dolt" 2>/dev/null | awk 'NR>1{print $1,$5,$6,$7,$8,$9}'; dotdolt_mtimes)
    if [ "$cur" != "$prev" ]; then
      { echo "--- $(date '+%T')"; printf '%s\n' "$cur"; lsof +D "$D/$DB" 2>/dev/null | awk 'NR>1{print $1,$2}' | sort -u; } >> "$X/dotdolt-watch.log"
      prev=$cur
    fi
    sleep 1
  done
}
watch_dolt_procs() {  # QUEM abriu: a cada 0,5 s anota, uma vez por processo novo com "dolt" na linha de comando, a cadeia de pais e o cwd (ga-06wmmp)
  local seen="$X/dotdolt-procs.seen" snap line pid cwd
  : > "$seen"
  # $$ é o PID do script principal também nesta subshell: se ele morrer sem tocar stop-watch (kill -9), o amostrador não vira órfão
  while [ ! -e "$X/stop-watch" ] && kill -0 $$ 2>/dev/null; do
    # vazio → nenhum processo dolt nesta amostra (o normal na janela); ps falhou/ilegível → amostra perdida, a próxima tenta de novo, nada é gravado
    snap=$(ps -axww -o pid=,ppid=,command= 2>/dev/null) || snap=""
    if [ -n "$snap" ]; then
      printf '%s\n' "$snap" | awk -v seen="$seen" -v now="$(date '+%T')" '
        BEGIN { while ((getline l < seen) > 0) S[l] = 1; close(seen) }
        { c = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", c); P[$1] = $2; C[$1] = c }
        END {
          for (p in C) {
            if (C[p] !~ /[Dd]olt/ || C[p] ~ /awk -v seen=|ps -axww/) continue
            # as ferramentas do próprio vigia (ls -la / stat / lsof +D sobre $D/$DB, que tem ".beads/dolt" no caminho) casam /[Dd]olt/ e
            # viravam "processo dolt novo" a cada segundo: filtra pela 1ª palavra da linha de comando (o programa), não pelo caminho que ele lê
            w = C[p]; sub(/ .*/, "", w); sub(/.*\//, "", w)
            if (w ~ /^(ls|stat|lsof)$/) continue
            key = p " " substr(C[p], 1, 60)
            if (key in S) continue
            chain = ""; q = p; n = 0
            while ((q in C) && n < 8) { chain = chain (chain == "" ? "" : "  <-  ") q ": " substr(C[q], 1, 110); q = P[q]; n++ }
            print now " pid=" p " " chain
            print key >> seen
          }
        }' | while IFS= read -r line; do
          printf '%s\n' "$line"
          pid=${line#*pid=}; pid=${pid%% *}
          # falhou/ilegível → "?" (o processo pode já ter saído), nunca um caminho inventado
          cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
          printf '  cwd: %s\n' "${cwd:-?}"
        done >> "$X/dotdolt-procs.log"
    fi
    sleep 0.5 2>/dev/null || sleep 1
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

log "=== hqswap $MODE: D=$D X=$X nó=$NODE:$NODE_DIR mbp=$MBP:$MBP_DIR flatten=$FLATTEN"
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
rm -f "$X/stop-watch"; watch_dotdolt & WATCH_PID=$!; watch_dolt_procs & WATCH_PROCS_PID=$!
log "5b vigias ligados: $X/dotdolt-watch.log (horário em segundos de .dolt e noms) e $X/dotdolt-procs.log (QUEM: cadeia de pais e cwd de cada processo dolt novo)"

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

# 9. (flatten) + GC + contagens + fsck no nó
if [ "$FLATTEN" = 1 ]; then
  flatten_script | node "cd $NODE_DIR && bash -s -- ~/$NODE_DOLT" > "$X/flatten.log" 2>&1 \
    || die "flatten no nó falhou ($X/flatten.log: $(tail -1 "$X/flatten.log"))"
  log "9a $(tail -1 "$X/flatten.log")"
fi
node "cd $NODE_DIR && ~/$NODE_DOLT gc --full --archive-level=0 --incremental-file-size=1073741824" > "$X/gc.log" 2>&1 \
  || die "dolt gc no nó falhou ($X/gc.log)"
node_counts > "$X/after-gc.txt"
grep -qiE 'error|not found' "$X/after-gc.txt" && die "erro nas contagens depois do GC: $(cat "$X/after-gc.txt")"
if [ "$FLATTEN" = 1 ]; then  # HEAD novo de propósito; o resto tem de ser idêntico à base
  CHECK_HEAD=$(awk '$1=="HEAD"{print $2}' "$X/after-gc.txt")
  [ -n "$CHECK_HEAD" ] && [ "$CHECK_HEAD" != "$BASE_HEAD" ] || die "HEAD depois do flatten inválido: [$CHECK_HEAD]"
  grep -v '^HEAD ' "$X/base.txt" > "$X/base-rows.txt"; grep -v '^HEAD ' "$X/after-gc.txt" > "$X/after-rows.txt"
  diff -u "$X/base-rows.txt" "$X/after-rows.txt" || die "contagens mudaram com o flatten/GC"
  { echo "HEAD $CHECK_HEAD"; cat "$X/base-rows.txt"; } > "$X/base-check.txt"
else
  diff -u "$X/base.txt" "$X/after-gc.txt" || die "contagens/HEAD mudaram com o GC"
  CHECK_HEAD=$BASE_HEAD; cp "$X/base.txt" "$X/base-check.txt"
fi
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
live_counts "$CHECK_HEAD" > "$X/live.txt"
grep -E "^(HEAD|$(echo $VERSIONED | tr ' ' '|')) " "$X/base-check.txt" | diff -u - "$X/live.txt" \
  || die "servidor novo difere da base nas tabelas versionadas (Dolt está NO AR com o hq novo; hq antigo no MacBook)"
live_ignored > "$X/live-ignored.txt"
grep -vE "^(HEAD|$(echo $VERSIONED | tr ' ' '|')) " "$X/base-check.txt" | diff -u - "$X/live-ignored.txt" \
  && log "12 tabelas ignoradas iguais à base" || log "AVISO: tabelas ignoradas diferem da base (pode ser gravação nova depois do start) — conferir $X/live-ignored.txt"
log "12 servidor novo conferido; hq agora $(du -sh "$D/$DB" | cut -f1)"
[ "$FLATTEN" = 1 ] && log "histórico completo (antes do flatten) só na cópia do MacBook $MBP:$MBP_DIR e no S3 — NÃO apagar em 24 h"
[ -d "$X/hq.old" ] && log "hq.old ainda em $X/hq.old (apagar depois de 24 h ou quando o disco pedir)"
touch "$X/stop-watch"
finish
log "13-14 cidade retomada, vigias de volta (HALT da rotina de compactação FICA)"
notify_ "hqswap OK: hq agora $(du -sh "$D/$DB" | cut -f1), cidade retomada."
log "=== fim OK"
exit 0
