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
#   loopback   par em 127.* ou ::ffff:127.* (IPv4)       — passa a funcionar com bind 127.0.0.1
#   loopback6  par em [::1] (IPv6)                         — o listener de hoje é dual-stack ("IPv6
#                                                           *:52756"); com bind 127.0.0.1 ele vira
#                                                           SÓ IPv4 e um cliente que fala ::1 leva
#                                                           ECONNREFUSED (medido). Conservador: um
#                                                           cliente "localhost" que cai sozinho para
#                                                           IPv4 também apareceria aqui; a sonda não
#                                                           distingue, então descubra quem é antes
#   self_lan   par == endereço local não-loopback          — cliente DESTA máquina que usa o IP
#                                                           da LAN/hostname; QUEBRA com bind 127.0.0.1
#   remote     qualquer outro par                          — outra máquina; QUEBRA com bind 127.0.0.1
#
# TRÊS ESTADOS por amostra, nunca colapsados (um "não consegui ver" não pode virar "limpo"):
#   clean        li os sockets e nenhum é loopback6/self_lan/remote (total=0 = ninguém conectado,
#                também clean)
#   nonloopback  vi pelo menos um loopback6/self_lan/remote — isto é, um cliente que o bind
#                127.0.0.1 deixaria de atender (o nome vem da pergunta "chega pelo IPv4 loopback?")
#   unknown      sem PID do Dolt, sem porta de LISTEN, lsof falhou ou estourou o tempo
#
# LIMITE HONESTO: é um retrato a cada ~60 s. Cliente remoto que conecta por centenas de
# milissegundos uma vez por dia pode passar sem ser visto. O veredito LIMPO diz "nenhuma
# conexão não-loopback em N amostras ao longo de H horas", não "nunca existiu". A rede de
# segurança do bind é que o erro de um cliente esquecido é ALTO (conexão recusada), e a volta
# é o rollback normal da janela de engine (binário anterior) — ver o README do patch em
# docs/pending-engine-window/ga-k7o6ou-dolt-bind-loopback.README.md.
#
# O LOG É LIDO COM DESCONFIANÇA: o report só aceita a linha que casa, inteira, com o formato
# exato que o emit escreve; o resto conta como "ilegível". Um append cortado no meio (ENOSPC —
# o volume de dados encheu em 15/10 21:09 — ou kill) é fechado com \n pelo próximo emit, para
# não colar no registro seguinte; e uma linha ilegível que cita "nonloopback" impede o LIMPO
# (não dá para datar, então não dá para provar que está fora da janela).
#
# Detection-only: não muda nada no Dolt nem na rede. Custo por amostra, medido em 15/10 com a
# máquina a load 83: ~0,17 s de CPU (a parede foi 5-8 s, fila de escalonamento). Um lsof
# limitado a UM pid (não varre a máquina) mais o do dolt-pid-lib, e um append. Single-instance
# por lock, log com teto de linhas.
#
# Lock: dono vivo nunca é retomado (um sampler lento não é furado); dono morto é retomado; lock
# sem pid legível só depois de velho (o dono caiu entre o mkdir e o echo). Um sampler PENDURADO
# (o dolt-pid-lib roda um lsof sem limite de tempo antes do limitado) segura o lock e a sonda
# para de amostrar — isso aparece no report como INSUFICIENTE ("a última amostra é velha"),
# nunca como LIMPO.
#
# Env: GC_CITY, DOLT_PEER_AUDIT_LOG, DOLT_PEER_AUDIT_LOCK, DOLT_PEER_AUDIT_MAX_LINES (20000),
#      DOLT_PEER_AUDIT_LSOF_TIMEOUT (15 s), DOLT_PEER_AUDIT_MAX_GAP (900 s — vale também para
#      o trecho contínuo só de unknown), DOLT_PEER_AUDIT_MAX_UNKNOWN_PCT (10),
#      DOLT_PEER_AUDIT_LOCK_STALE_MIN (10 min — idade de um lock sem pid legível)
set -uo pipefail
# Locale fixo: o log é ASCII + bytes crus e o awk do macOS morre ("towc: multibyte conversion
# failure") numa linha cortada no meio de um caractere multibyte quando o locale é UTF-8 — o
# `report 48` de um shell interativo ficava sem veredito até a linha sair do log. Em C o awk lê
# bytes, a linha cortada vira "ilegível" e o veredito sai igual em qualquer shell (e igual ao do launchd).
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GC_CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
export GC_CITY
LOG="${DOLT_PEER_AUDIT_LOG:-$GC_CITY/.gc/logs/dolt-remote-peers.jsonl}"
LOCKD="${DOLT_PEER_AUDIT_LOCK:-$GC_CITY/.gc/dolt-remote-peer-audit.lock.d}"
MAX_LINES="${DOLT_PEER_AUDIT_MAX_LINES:-20000}"
LSOF_TIMEOUT="${DOLT_PEER_AUDIT_LSOF_TIMEOUT:-15}"
MAX_GAP="${DOLT_PEER_AUDIT_MAX_GAP:-900}"
MAX_UNKNOWN_PCT="${DOLT_PEER_AUDIT_MAX_UNKNOWN_PCT:-10}"
LOCK_STALE_MIN="${DOLT_PEER_AUDIT_LOCK_STALE_MIN:-10}"

# shellcheck source=dolt-pid-lib.sh
. "$SELF_DIR/dolt-pid-lib.sh"

# lsof limitado no tempo: sob carga o lsof pode pendurar, e uma sonda pendurada vira a carga
# que devia observar. perl vem com o macOS; estourar o tempo dá exit 142 (SIGALRM).
bounded_lsof() { perl -e 'alarm shift; exec @ARGV' "$LSOF_TIMEOUT" lsof "$@"; }

# Grava UMA linha no log. Estado e motivo vêm de quem chama; contagens ficam em 0 no unknown.
# O formato é o que o report exige por inteiro (ver okline lá): mexeu aqui, mexa lá.
emit() {
  local state="$1" why="$2" pid="$3" ports="$4" total="$5" loop="$6" loop6="$7" selflan="$8" remote="$9" peers="${10}"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # Um append anterior pode ter sido cortado no meio (ENOSPC, kill) ou deixado uma cauda de zeros
  # (queda/reboot pode deixar NUL onde o append não chegou ao disco — modo de falha conhecido, não
  # medido aqui; o teste B8 simula a cauda): sem \n no fim, este
  # registro colaria nessa ponta e o report leria as duas como UMA linha. O último byte sai em
  # hexa pelo od porque `$(tail -c 1)` DESCARTA o NUL — uma cauda de zeros parecia "termina em \n".
  # Último byte: vazio → log novo/inexistente, nada a fechar; 0a → já termina em linha, nada a
  # fechar; qualquer outro (inclusive 00) → fecho com \n; falhou/ilegível → vazio, ou seja não fecho
  # às cegas (o report ainda conta como ilegível o que não casar com o formato).
  local lead="" lastbyte
  lastbyte="$(tail -c 1 "$LOG" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ -n "$lastbyte" ] && [ "$lastbyte" != 0a ] && lead=$'\n'
  printf '%s{"ts":"%s","epoch":%s,"state":"%s","pid":"%s","ports":"%s","total":%s,"loopback":%s,"loopback6":%s,"self_lan":%s,"remote":%s,"peers":%s,"why":"%s"}\n' \
    "$lead" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$state" "$pid" "$ports" \
    "$total" "$loop" "$loop6" "$selflan" "$remote" "$peers" "$why" >>"$LOG" 2>/dev/null || {
      echo "dolt-remote-peer-audit: não consegui gravar $LOG" >&2; return 1; }
  # Teto do log: ~230 KB/dia a 60 s (linha de ~165 bytes), 20000 linhas ≈ 14 dias; só corta
  # quando passa do limite, mantendo o fim.
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
  # lock existente: só vale se o dono ainda vive. Dono vivo = não pego, nunca por idade.
  # pid ilegível = não sei = não pego, MAS só enquanto o lock é novo (o dono pode estar entre o
  # mkdir e o echo); um lock sem pid que ficou velho é de dono que caiu nessa janela e, sem
  # retomada, a sonda calaria para sempre.
  local owner stale=0
  owner="$(cat "$LOCKD/pid" 2>/dev/null)"
  if [ -z "$owner" ]; then
    # idade do lock: velho → imprime o caminho; novo → vazio; falhou (find, valor não numérico
    # em LOCK_STALE_MIN) → vazio também, ou seja "não sei a idade" = não pego (estado inerte).
    [ -n "$(find "$LOCKD" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ] && stale=1
  elif ! kill -0 "$owner" 2>/dev/null; then
    stale=1
  fi
  if [ "$stale" = 1 ]; then
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
    emit unknown "sem pid do dolt" "" "" 0 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — não identifiquei o processo do Dolt" >&2
    return 2
  fi

  # UM retrato do pid (LISTEN + ESTABLISHED no mesmo instante). vazio → unknown (nem o LISTEN
  # apareceu, então não posso afirmar que li os sockets); falhou/estourou (rc ≥ 2) → unknown.
  snap="$(bounded_lsof -nP -a -p "$pid" -iTCP 2>/dev/null)"
  rc=$?
  ports="$(printf '%s\n' "$snap" | awk 'NR>1 && /\(LISTEN\)/ { n=$9; sub(/^.*:/,"",n); if (n ~ /^[0-9]+$/) p[n]=1 } END { s=""; for (k in p) s = s (s==""?"":",") k; print s }')"
  if [ "$rc" -ge 2 ] || [ -z "$ports" ]; then
    emit unknown "lsof falhou (rc=$rc) ou sem LISTEN visível" "$pid" "" 0 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — lsof rc=$rc, sem porta de LISTEN para o pid $pid" >&2
    return 2
  fi
  # LISTEN presente no mesmo retrato = lsof funcionou; sem linha ESTABLISHED = ninguém conectado.
  est="$(printf '%s\n' "$snap" | awk 'NR==1 || /\(ESTABLISHED\)/')"

  # total|loopback|loopback6|self_lan|remote|{peers}; peer com caractere fora do esperado vira "?"
  # (a linha é JSON montado à mão — nada vindo do lsof entra sem validar). [::1] é o único par
  # IPv6 de loopback que o lsof imprime e tem balde próprio: o bind 127.0.0.1 não o atende.
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
      if (rhost ~ /^127\./ || rhost ~ /^\[::ffff:127\./) loop++
      else if (rhost == "[::1]") { loop6++; peers[rhost]++ }
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
      printf "%d|%d|%d|%d|%d|%s\n", total + 0, loop + 0, loop6 + 0, selflan + 0, remote + 0, pj
    }')"
  if ! printf '%s' "$parsed" | grep -Eq '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|\{.*\}$'; then
    emit unknown "saída do lsof ilegível" "$pid" "$ports" 0 0 0 0 0 '{}'
    echo "dolt-remote-peer-audit: UNKNOWN — não consegui ler a saída do lsof" >&2
    return 2
  fi

  local total loop loop6 selflan remote peers state
  IFS='|' read -r total loop loop6 selflan remote peers <<<"$parsed"
  if [ $((loop6 + selflan + remote)) -gt 0 ]; then state=nonloopback; else state=clean; fi
  emit "$state" "" "$pid" "$ports" "$total" "$loop" "$loop6" "$selflan" "$remote" "$peers"
  if [ "$state" = nonloopback ]; then
    echo "dolt-remote-peer-audit: NONLOOPBACK — loopback6=$loop6 self_lan=$selflan remote=$remote peers=$peers" >&2
    return 1
  fi
  return 0
}

report() {
  local hours="${1:-48}"
  # Horas são decimais. Só dígitos, e no máximo 6 (sem estourar a aritmética do bash); depois o
  # 10# tira o zero à esquerda do caminho do octal: "08"/"09" davam erro de aritmética (exit 1,
  # o mesmo código do BLOQUEADO, sem veredito) e "010" virava 8 h calado enquanto o cabeçalho
  # dizia 10 h. Zero (qualquer grafia) não é janela.
  case "$hours" in ''|*[!0-9]*) echo "uso: $0 report [HORAS inteiras > 0]" >&2; return 64 ;; esac
  if [ "${#hours}" -gt 6 ] || [ "$((10#$hours))" -eq 0 ]; then
    echo "uso: $0 report [HORAS inteiras > 0, até 6 dígitos]" >&2; return 64
  fi
  hours=$((10#$hours))
  # vazio/ausente → INSUFICIENTE (a sonda nunca rodou); ilegível → conta como linha ruim abaixo.
  if [ ! -r "$LOG" ]; then
    echo "INSUFICIENTE: sem log em $LOG — a sonda nunca rodou aqui."
    return 2
  fi
  local now since
  now="$(date +%s)"; since=$((now - hours * 3600))
  awk -v since="$since" -v now="$now" -v hours="$hours" -v maxgap="$MAX_GAP" -v maxunk="$MAX_UNKNOWN_PCT" '
    # Só vira amostra a linha que casa, INTEIRA, com o formato do emit (campos, ordem, tipos).
    # Achar "epoch" e "state" em qualquer ponto da linha não basta: um registro cortado, ou dois
    # colados numa linha só, passaria, e a primeira ocorrência de cada chave valeria pela linha
    # toda (foi assim que um nonloopback colado numa ponta cortada saiu como LIMPO, ilegíveis: 0).
    $0 !~ /^\{"ts":"[0-9TZ:-]*","epoch":[0-9]+,"state":"(clean|nonloopback|unknown)","pid":"[0-9]*","ports":"[0-9,]*","total":[0-9]+,"loopback":[0-9]+,"loopback6":[0-9]+,"self_lan":[0-9]+,"remote":[0-9]+,"peers":\{[^{}]*\},"why":"[^"]*"\}$/ {
      bad++
      # Ilegível que cita nonloopback: não dá para datar, logo não dá para provar que está fora
      # da janela. Não pode virar LIMPO (ver END).
      if ($0 ~ /nonloopback/) badnl++
      next
    }
    {
      match($0, /"epoch":[0-9]+/); e = substr($0, RSTART + 8, RLENGTH - 8) + 0
      match($0, /"state":"[a-z]+"/); s = substr($0, RSTART + 9, RLENGTH - 10)
      if (e < since) next
      n++; cnt[s]++
      if (first == "" || e < first) first = e
      if (e > last) last = e
      if (prev != "" && e - prev > maxgap && e - prev > gap) gap = e - prev
      prev = e
      # Trecho contínuo só de unknown: a porcentagem sozinha deixava 10% de 48 h (~4,8 h) ser UM
      # trecho cego. Unknown é amostra que não viu nada, então vale o mesmo teto do buraco.
      if (s == "unknown") {
        if (ustart == "") ustart = e
        ulast = e
      } else if (ustart != "") {
        if (ulast - ustart > urun) urun = ulast - ustart
        ustart = ""
      }
      if (s == "nonloopback") {
        pe = "?"
        if (match($0, /"peers":\{[^}]*\}/)) pe = substr($0, RSTART + 8, RLENGTH - 8)
        seen[pe] = e; nseen[pe]++
      }
    }
    END {
      printf "janela: últimas %dh | amostras: %d (clean=%d nonloopback=%d unknown=%d) | linhas ilegíveis: %d\n", hours, n, cnt["clean"], cnt["nonloopback"], cnt["unknown"], bad
      if (n > 0) printf "cobertura: %.1fh (primeira amostra há %.1fh, última há %.0fmin) | maior buraco: %ds\n", (last - first) / 3600, (now - first) / 3600, (now - last) / 60, gap
      if (ustart != "" && ulast - ustart > urun) urun = ulast - ustart
      if (cnt["nonloopback"] > 0) {
        print "BLOQUEADO: houve cliente que o bind 127.0.0.1 deixaria de atender (fora do IPv4 loopback):"
        for (p in seen) {
          printf "  %s  (%d amostras; visto por último há %dmin)\n", p, nseen[p], (now - seen[p]) / 60
          if (index(p, "[::1]")) v6 = 1
        }
        if (v6) print "  ([::1] = IPv6: o bind 127.0.0.1 deixa o listener só IPv4 e recusa esse cliente; descubra quem é antes de liberar)"
        exit 1
      }
      why = ""
      if (badnl > 0) why = why badnl " linha(s) ilegível(is) citam nonloopback e não dá para datar (pode ter sido cliente fora do loopback); "
      if (n == 0) why = why "nenhuma amostra na janela; "
      else {
        if (first > since + maxgap) why = why "a primeira amostra da janela é tardia demais (cobertura incompleta no começo); "
        if (last < now - maxgap) why = why "a última amostra é velha (a sonda parou?); "
        if (gap > 0) why = why "há buraco de " gap "s entre amostras (> " maxgap "s); "
        if (urun > maxgap) why = why "há trecho de " urun "s só com unknown (> " maxgap "s); "
        if (cnt["unknown"] * 100 / n > maxunk) why = why sprintf("unknown em %.0f%% das amostras (> %d%%); ", cnt["unknown"] * 100 / n, maxunk)
        if (bad / (n + bad) > 0.01) why = why "mais de 1% de linhas ilegíveis; "
      }
      if (why != "") { print "INSUFICIENTE: " why; exit 2 }
      printf "LIMPO: nenhum cliente fora do IPv4 loopback em %d leituras válidas (+%d unknown) ao longo de %.1fh.\n", n - cnt["unknown"], cnt["unknown"], (last - first) / 3600
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
