#!/usr/bin/env bash
# dolt-remote-peer-audit.sh (ga-k7o6ou) — algum cliente do Dolt vem de FORA do loopback?
#
# Uso:  dolt-remote-peer-audit.sh [sample]        uma amostra (é o que o launchd roda)
#       dolt-remote-peer-audit.sh report [HORAS]  veredito sobre as últimas HORAS (padrão 48)
#
# POR QUE EXISTE: o Dolt gerenciado escuta em 0.0.0.0 (todas as interfaces), usuário root,
# senha vazia. O patch do ga-k7o6ou troca o bind para 127.0.0.1 — o que derruba, com erro
# alto no cliente, qualquer cliente que NÃO chegue pelo loopback. A decisão original do
# bead foi medir 48 h antes de religar o Dolt assim; esta sonda é a medição.
#
# POR QUE NÃO USAR O dolt-load-attributor: ele só conta linhas do lsof com COMMAND != "dolt",
# ou seja, sockets do lado CLIENTE que têm PID local. Cliente remoto não tem socket local:
# some daquele log por construção (nem aparece como "?"). Esta sonda faz a consulta
# INVERTIDA — olha os sockets do próprio Dolt e classifica o endereço do par.
#
# O QUE CONTA COMO CLIENTE: só socket cuja porta LOCAL é uma porta em que o Dolt escuta
# (as conexões de saída do Dolt, ex. backup para o S3, não são clientes). Cada um vira:
#   loopback  par em 127.*, ::1 ou ::ffff:127.*           — passa a funcionar com bind 127.0.0.1
#   self_lan  par == endereço local não-loopback          — cliente DESTA máquina que usa o IP
#                                                           da LAN/hostname; QUEBRA com bind 127.0.0.1
#   remote    qualquer outro par                          — outra máquina; QUEBRA com bind 127.0.0.1
#
# TRÊS ESTADOS por amostra, nunca colapsados (um "não consegui ver" não pode virar "limpo"):
#   clean        li os sockets e nenhum é self_lan/remote (total=0 = ninguém conectado, também clean)
#   nonloopback  vi pelo menos um self_lan/remote
#   unknown      sem PID do Dolt, sem porta de LISTEN, lsof falhou ou estourou o tempo
#
# LIMITE HONESTO: é um retrato a cada ~60 s. Cliente remoto que conecta por centenas de
# milissegundos uma vez por dia pode passar sem ser visto. O veredito LIMPO diz "nenhuma
# conexão não-loopback em N amostras ao longo de H horas", não "nunca existiu". A rede de
# segurança do bind é que o erro de um cliente esquecido é ALTO (conexão recusada), e a volta
# é GC_DOLT_HOST=0.0.0.0 + reinício (ver o runbook).
#
# Detection-only: não muda nada no Dolt nem na rede. Custo por amostra, medido em 15/10 com a
# máquina a load 83: ~0,17 s de CPU (a parede foi 5-8 s, fila de escalonamento). Um lsof
# limitado a UM pid (não varre a máquina) mais o do dolt-pid-lib, e um append. Single-instance
# por lock, log com teto de linhas.
#
# Env: GC_CITY, DOLT_PEER_AUDIT_LOG, DOLT_PEER_AUDIT_LOCK, DOLT_PEER_AUDIT_MAX_LINES (20000),
#      DOLT_PEER_AUDIT_LSOF_TIMEOUT (15 s), DOLT_PEER_AUDIT_MAX_GAP (900 s),
#      DOLT_PEER_AUDIT_MAX_UNKNOWN_PCT (10)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GC_CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
export GC_CITY
LOG="${DOLT_PEER_AUDIT_LOG:-$GC_CITY/.gc/logs/dolt-remote-peers.jsonl}"
LOCKD="${DOLT_PEER_AUDIT_LOCK:-$GC_CITY/.gc/dolt-remote-peer-audit.lock.d}"
MAX_LINES="${DOLT_PEER_AUDIT_MAX_LINES:-20000}"
LSOF_TIMEOUT="${DOLT_PEER_AUDIT_LSOF_TIMEOUT:-15}"
MAX_GAP="${DOLT_PEER_AUDIT_MAX_GAP:-900}"
MAX_UNKNOWN_PCT="${DOLT_PEER_AUDIT_MAX_UNKNOWN_PCT:-10}"

# shellcheck source=dolt-pid-lib.sh
. "$SELF_DIR/dolt-pid-lib.sh"

# lsof limitado no tempo: sob carga o lsof pode pendurar, e uma sonda pendurada vira a carga
# que devia observar. perl vem com o macOS; estourar o tempo dá exit 142 (SIGALRM).
bounded_lsof() { perl -e 'alarm shift; exec @ARGV' "$LSOF_TIMEOUT" lsof "$@"; }

# Grava UMA linha no log. Estado e motivo vêm de quem chama; contagens ficam em 0 no unknown.
emit() {
  local state="$1" why="$2" pid="$3" ports="$4" total="$5" loop="$6" selflan="$7" remote="$8" peers="$9"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '{"ts":"%s","epoch":%s,"state":"%s","pid":"%s","ports":"%s","total":%s,"loopback":%s,"self_lan":%s,"remote":%s,"peers":%s,"why":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$state" "$pid" "$ports" \
    "$total" "$loop" "$selflan" "$remote" "$peers" "$why" >>"$LOG" 2>/dev/null || {
      echo "dolt-remote-peer-audit: não consegui gravar $LOG" >&2; return 1; }
  # Teto do log: ~57 KB/dia a 60 s; só corta quando passa do limite, mantendo o fim.
  local n
  n="$(wc -l <"$LOG" 2>/dev/null | tr -d ' ')"
  if [ -n "$n" ] && [ "$n" -gt "$MAX_LINES" ] 2>/dev/null; then
    tail -n $((MAX_LINES * 3 / 4)) "$LOG" >"$LOG.trim.$$" 2>/dev/null && mv "$LOG.trim.$$" "$LOG" 2>/dev/null
    rm -f "$LOG.trim.$$" 2>/dev/null
  fi
  return 0
}

take_lock() {
  mkdir -p "$(dirname "$LOCKD")" 2>/dev/null || true
  if mkdir "$LOCKD" 2>/dev/null; then echo $$ >"$LOCKD/pid"; return 0; fi
  # lock existente: só vale se o dono ainda vive. pid ilegível = não sei = não pego o lock.
  local owner
  owner="$(cat "$LOCKD/pid" 2>/dev/null)"
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$LOCKD" 2>/dev/null
    if mkdir "$LOCKD" 2>/dev/null; then echo $$ >"$LOCKD/pid"; return 0; fi
  fi
  return 1
}

sample() {
  if ! take_lock; then
    echo "dolt-remote-peer-audit: outra instância em andamento — pulo esta amostra" >&2
    return 0
  fi
  trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT

  local pid snap rc ports est parsed
  # vazio → unknown (sem pid do Dolt); falhou/ilegível → idem. Nunca vira "clean".
  pid="$(dolt_server_pid)"
  if [ -z "$pid" ]; then
    emit unknown "sem pid do dolt" "" "" 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — não identifiquei o processo do Dolt" >&2
    return 2
  fi

  # UM retrato do pid (LISTEN + ESTABLISHED no mesmo instante). vazio → unknown (nem o LISTEN
  # apareceu, então não posso afirmar que li os sockets); falhou/estourou (rc ≥ 2) → unknown.
  snap="$(bounded_lsof -nP -a -p "$pid" -iTCP 2>/dev/null)"
  rc=$?
  ports="$(printf '%s\n' "$snap" | awk 'NR>1 && /\(LISTEN\)/ { n=$9; sub(/^.*:/,"",n); if (n ~ /^[0-9]+$/) p[n]=1 } END { s=""; for (k in p) s = s (s==""?"":",") k; print s }')"
  if [ "$rc" -ge 2 ] || [ -z "$ports" ]; then
    emit unknown "lsof falhou (rc=$rc) ou sem LISTEN visível" "$pid" "" 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — lsof rc=$rc, sem porta de LISTEN para o pid $pid" >&2
    return 2
  fi
  # LISTEN presente no mesmo retrato = lsof funcionou; sem linha ESTABLISHED = ninguém conectado.
  est="$(printf '%s\n' "$snap" | awk 'NR==1 || /\(ESTABLISHED\)/')"

  # total|loopback|self_lan|remote|{peers}; peer com caractere fora do esperado vira "?"
  # (a linha é JSON montado à mão — nada vindo do lsof entra sem validar).
  parsed="$(printf '%s\n' "$est" | awk -v ports="$ports" '
    BEGIN { n = split(ports, P, ","); for (i = 1; i <= n; i++) isport[P[i]] = 1 }
    NR > 1 {
      name = ""
      for (i = 1; i <= NF; i++) if ($i ~ /->/) { name = $i; break }
      if (name == "") next
      split(name, sd, "->"); L = sd[1]; R = sd[2]
      lport = L; sub(/^.*:/, "", lport)
      if (!(lport in isport)) next
      lhost = L; sub(/:[^:]*$/, "", lhost)
      rhost = R; sub(/:[^:]*$/, "", rhost)
      total++
      if (rhost ~ /^127\./ || rhost == "[::1]" || rhost ~ /^\[::ffff:127\./) loop++
      else {
        if (rhost == lhost) selflan++; else remote++
        if (rhost !~ /^[][0-9A-Za-z:.%-]+$/) rhost = "?"
        peers[rhost]++
      }
    }
    END {
      pj = "{"; sep = ""
      for (k in peers) { pj = pj sep "\"" k "\":" peers[k]; sep = "," }
      pj = pj "}"
      printf "%d|%d|%d|%d|%s\n", total + 0, loop + 0, selflan + 0, remote + 0, pj
    }')"
  if ! printf '%s' "$parsed" | grep -Eq '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|\{.*\}$'; then
    emit unknown "saída do lsof ilegível" "$pid" "$ports" 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — não consegui ler a saída do lsof" >&2
    return 2
  fi

  local total loop selflan remote peers state
  IFS='|' read -r total loop selflan remote peers <<<"$parsed"
  if [ $((selflan + remote)) -gt 0 ]; then state=nonloopback; else state=clean; fi
  emit "$state" "" "$pid" "$ports" "$total" "$loop" "$selflan" "$remote" "$peers"
  if [ "$state" = nonloopback ]; then
    echo "dolt-remote-peer-audit: NONLOOPBACK — self_lan=$selflan remote=$remote peers=$peers" >&2
    return 1
  fi
  return 0
}

report() {
  local hours="${1:-48}"
  case "$hours" in ''|*[!0-9]*|0) echo "uso: $0 report [HORAS inteiras > 0]" >&2; return 64 ;; esac
  # vazio/ausente → INSUFICIENTE (a sonda nunca rodou); ilegível → conta como linha ruim abaixo.
  if [ ! -r "$LOG" ]; then
    echo "INSUFICIENTE: sem log em $LOG — a sonda nunca rodou aqui."
    return 2
  fi
  local now since
  now="$(date +%s)"; since=$((now - hours * 3600))
  awk -v since="$since" -v now="$now" -v hours="$hours" -v maxgap="$MAX_GAP" -v maxunk="$MAX_UNKNOWN_PCT" '
    {
      e = ""; s = ""
      if (match($0, /"epoch":[0-9]+/)) e = substr($0, RSTART + 8, RLENGTH - 8)
      if (match($0, /"state":"[a-z]+"/)) s = substr($0, RSTART + 9, RLENGTH - 10)
      if (e == "" || s == "" || (s != "clean" && s != "nonloopback" && s != "unknown")) { bad++; next }
      e += 0
      if (e < since) next
      n++; cnt[s]++
      if (first == "" || e < first) first = e
      if (e > last) last = e
      if (prev != "" && e - prev > maxgap && e - prev > gap) gap = e - prev
      prev = e
      if (s == "nonloopback") {
        pe = "?"
        if (match($0, /"peers":\{[^}]*\}/)) pe = substr($0, RSTART + 8, RLENGTH - 8)
        seen[pe] = e; nseen[pe]++
      }
    }
    END {
      printf "janela: últimas %dh | amostras: %d (clean=%d nonloopback=%d unknown=%d) | linhas ilegíveis: %d\n", hours, n, cnt["clean"], cnt["nonloopback"], cnt["unknown"], bad
      if (n > 0) printf "cobertura: %.1fh (primeira amostra há %.1fh, última há %.0fmin) | maior buraco: %ds\n", (last - first) / 3600, (now - first) / 3600, (now - last) / 60, gap
      if (cnt["nonloopback"] > 0) {
        print "BLOQUEADO: houve cliente que NÃO chega pelo loopback — o bind 127.0.0.1 quebraria:"
        for (p in seen) printf "  %s  (%d amostras; visto por último há %dmin)\n", p, nseen[p], (now - seen[p]) / 60
        exit 1
      }
      why = ""
      if (n == 0) why = why "nenhuma amostra na janela; "
      else {
        if (first > since + maxgap) why = why "a primeira amostra da janela é tardia demais (cobertura incompleta no começo); "
        if (last < now - maxgap) why = why "a última amostra é velha (a sonda parou?); "
        if (gap > 0) why = why "há buraco de " gap "s entre amostras (> " maxgap "s); "
        if (cnt["unknown"] * 100 / n > maxunk) why = why sprintf("unknown em %.0f%% das amostras (> %d%%); ", cnt["unknown"] * 100 / n, maxunk)
        if (bad / (n + bad) > 0.01) why = why "mais de 1% de linhas ilegíveis; "
      }
      if (why != "") { print "INSUFICIENTE: " why; exit 2 }
      printf "LIMPO: nenhuma conexão não-loopback em %d amostras ao longo de %.1fh.\n", n, (last - first) / 3600
      print "(retrato periódico: não prova que cliente raro e de milissegundos não existe — ver o cabeçalho.)"
      exit 0
    }
  ' "$LOG"
}

case "${1:-sample}" in
  sample) sample ;;
  report) report "${2:-48}" ;;
  *) echo "uso: $0 [sample | report [HORAS]]" >&2; exit 64 ;;
esac
