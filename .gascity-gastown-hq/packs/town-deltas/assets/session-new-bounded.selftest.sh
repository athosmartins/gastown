#!/usr/bin/env bash
# session-new-bounded.selftest.sh — prova o teto de tempo de `gc session new` nos dispatchers do gate (ga-29ssni).
#
# Critério de aceite da bead: "selftest 'gc session new trava' → spawn abortado em <= 150 s e log". Aqui um `gc` de
# verdade (script no PATH, que dorme) trava, o teto é encurtado por GATE_SPAWN_TIMEOUT_SECS para o teste caber em
# segundos, e a prova é: o spawn termina no teto, o rc é o do timeout, e o stderr capturado carrega a linha
# `spawn_timeout:` que o gate lê. Sem Dolt, sem gc real, sem launchd.
#
# Seções:
#   1. saneamento dos knobs (0 / texto / vazio nunca chegam ao `timeout`);
#   2. o `gc` trava → abortado no teto, rc 124, marcador no stderr;
#   3. `gc` que ignora SIGTERM → o SIGKILL do `-k` ainda o derruba;
#   4. três estados: terminou bem / terminou com erro / estourou — o erro comum NÃO vira timeout;
#   5. `gc` simulado por função (como os outros selftests do gate) passa direto, sem `timeout`;
#   6. sem `timeout`/`gtimeout` no PATH → roda sem teto e avisa (nunca derruba o spawn);
#   7. classificação: o texto do marcador é o mesmo que is_transient_spawn_error do gate casa;
#   8. o laço de retry em processo NÃO repete um spawn que estourou o teto;
#   9. fiação: toda chamada `gc ... session new` dos dois dispatchers passa por gate_bounded_spawn;
#  10. refino-gate: heartbeat carimbado na largada, em log/warn/err e a cada volta do laço de espera;
#      e o watchdog lê exatamente esse arquivo.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/session-new-bounded.lib.sh"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
REFINO="$SELF_DIR/refino-gate-dispatcher.sh"
DPW="$SELF_DIR/../../../scripts/daemon-presence-watchdog.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/snb-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"; mkdir -p "$STUBS"

echo "== session-new-bounded.selftest (ga-29ssni) =="
[ -r "$LIB" ] || { echo "FATAL: lib ausente: $LIB"; exit 1; }
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
  || { echo "FATAL: este selftest precisa de timeout/gtimeout no PATH"; exit 1; }

# ── gc de mentira, como ARQUIVO executável (o `timeout` só executa binário externo) ──────────────────────────────
cat > "$STUBS/gc-hang" <<'EOF'
#!/bin/sh
# trava como um `gc session new` com o Dolt fora: escreve o banner de sempre no stderr e dorme
echo 'warning: builtin pack "gastown" on disk differs from the copy embedded in this gc binary' >&2
sleep 60
EOF
cat > "$STUBS/gc-ignore-term" <<'EOF'
#!/bin/sh
# ignora SIGTERM (disposição "ignorado" é herdada pelo sleep): só o SIGKILL do `timeout -k` derruba
trap '' TERM
sleep 60
EOF
cat > "$STUBS/gc-ok" <<'EOF'
#!/bin/sh
printf '{"session_id":"sess-ok","session_name":"gate-reviewer-ok"}\n'
EOF
cat > "$STUBS/gc-fail" <<'EOF'
#!/bin/sh
echo 'listing sessions: invalid connection' >&2
exit 1
EOF
chmod +x "$STUBS"/gc-*

# roda um comando num bash limpo com o PATH apontando para o stub e a lib carregada.
# $1 = nome do stub (vira `gc`), demais = env VAR=valor antes do comando. Saída: "RC=<rc> OUT=<stdout> ERR=<stderr>".
run_spawn() {
  local stub="$1"; shift
  local d="$TMP/run.$RANDOM"; mkdir -p "$d/bin"
  cp "$STUBS/$stub" "$d/bin/gc"
  env "$@" PATH="$d/bin:$PATH" bash -c '
    source "'"$LIB"'"
    out=$(gate_bounded_spawn gc --city test session new gate-reviewer --no-attach --json 2>"'"$d"'/err"); rc=$?
    printf "RC=%s\n" "$rc"; printf "OUT=%s\n" "$out"; printf "ERR=%s\n" "$(cat "'"$d"'/err")"
  '
}

# ── 1. saneamento dos knobs ──────────────────────────────────────────────────
echo "── 1. knobs: 0 / texto / vazio nunca chegam ao timeout ──"
knob() { env "$@" bash -c 'source "'"$LIB"'" 2>/dev/null; printf "%s/%s" "$GATE_SPAWN_TIMEOUT_SECS" "$GATE_SPAWN_KILL_AFTER_SECS"'; }
eq "padrão = 150 s de teto e 10 s até o KILL (o mesmo teto do Pilot)" "$(knob X=1)" "150/10"
eq "GATE_SPAWN_TIMEOUT_SECS=0 volta a 150 (timeout 0 = sem limite)" "$(knob GATE_SPAWN_TIMEOUT_SECS=0)" "150/10"
eq "GATE_SPAWN_TIMEOUT_SECS=abc volta a 150 (o timeout recusaria rodar o gc)" "$(knob GATE_SPAWN_TIMEOUT_SECS=abc)" "150/10"
eq "GATE_SPAWN_TIMEOUT_SECS= (vazio) volta a 150" "$(knob GATE_SPAWN_TIMEOUT_SECS=)" "150/10"
eq "GATE_SPAWN_TIMEOUT_SECS=-5 volta a 150" "$(knob GATE_SPAWN_TIMEOUT_SECS=-5)" "150/10"
eq "valor válido é respeitado" "$(knob GATE_SPAWN_TIMEOUT_SECS=90 GATE_SPAWN_KILL_AFTER_SECS=3)" "90/3"
eq "GATE_SPAWN_KILL_AFTER_SECS=0 volta a 10" "$(knob GATE_SPAWN_KILL_AFTER_SECS=0)" "150/10"

# ── 2. o gc trava ────────────────────────────────────────────────────────────
echo "── 2. gc trava → abortado no teto, rc 124, marcador no stderr ──"
T0=$SECONDS
R="$(run_spawn gc-hang GATE_SPAWN_TIMEOUT_SECS=2 GATE_SPAWN_KILL_AFTER_SECS=2)"
ELAPSED=$(( SECONDS - T0 ))
eq "rc é o do timeout (124)" "$(printf '%s\n' "$R" | sed -n 's/^RC=//p')" "124"
if [ "$ELAPSED" -le 6 ]; then ok "abortou em ${ELAPSED}s (teto 2 s; o gc dormiria 60 s)"; else bad "demorou ${ELAPSED}s — o teto de 2 s não foi imposto"; fi
case "$R" in *"spawn_timeout:"*) ok "stderr carrega a linha spawn_timeout: (é o que o gate lê)" ;; *) bad "sem spawn_timeout: no stderr: $R" ;; esac
case "$R" in *"DESCONHECIDO"*) ok "a linha diz que o desfecho é desconhecido (a sessão pode existir)" ;; *) bad "a linha não avisa que a sessão pode ter sido criada" ;; esac
case "$R" in *"warning: builtin pack"*) ok "o stderr do próprio gc continua preservado junto do marcador" ;; *) bad "o stderr original do gc se perdeu" ;; esac
ERR_TXT="$(printf '%s\n' "$R" | sed -n '/^ERR=/,$p')"
eq "gate_spawn_err_is_timeout reconhece o stderr capturado" "$(bash -c 'source "'"$LIB"'" 2>/dev/null; gate_spawn_err_is_timeout "$1"' _ "$ERR_TXT")" "1"
eq "…e NÃO reconhece texto vazio (vazio ≠ timeout)" "$(bash -c 'source "'"$LIB"'" 2>/dev/null; gate_spawn_err_is_timeout ""')" "0"

# ── 3. gc que ignora SIGTERM ─────────────────────────────────────────────────
echo "── 3. gc que ignora SIGTERM → o -k derruba com SIGKILL ──"
T0=$SECONDS
R="$(run_spawn gc-ignore-term GATE_SPAWN_TIMEOUT_SECS=2 GATE_SPAWN_KILL_AFTER_SECS=1)"
ELAPSED=$(( SECONDS - T0 ))
eq "rc 137 (SIGKILL)" "$(printf '%s\n' "$R" | sed -n 's/^RC=//p')" "137"
if [ "$ELAPSED" -le 7 ]; then ok "derrubado em ${ELAPSED}s (2 s de teto + 1 s até o KILL)"; else bad "demorou ${ELAPSED}s — o -k não funcionou"; fi
case "$R" in *"spawn_timeout:"*) ok "o 137 provado pelo relógio também vira spawn_timeout:" ;; *) bad "137 depois do teto não foi marcado como timeout: $R" ;; esac

# ── 4. três estados ──────────────────────────────────────────────────────────
echo "── 4. terminou bem / terminou com erro / estourou — nunca colapsam ──"
R="$(run_spawn gc-ok GATE_SPAWN_TIMEOUT_SECS=5)"
eq "terminou bem: rc 0" "$(printf '%s\n' "$R" | sed -n 's/^RC=//p')" "0"
case "$R" in *'"session_id":"sess-ok"'*) ok "stdout (o JSON da sessão) chega intacto" ;; *) bad "stdout alterado: $R" ;; esac
case "$R" in *"spawn_timeout:"*) bad "um spawn BEM-SUCEDIDO foi marcado como timeout" ;; *) ok "sem marcador quando o spawn termina" ;; esac
R="$(run_spawn gc-fail GATE_SPAWN_TIMEOUT_SECS=5)"
eq "terminou com erro: rc 1 preservado" "$(printf '%s\n' "$R" | sed -n 's/^RC=//p')" "1"
case "$R" in *"invalid connection"*) ok "stderr do erro chega intacto" ;; *) bad "stderr do erro perdido: $R" ;; esac
case "$R" in *"spawn_timeout:"*) bad "um ERRO comum (rc 1) foi marcado como timeout — erro e estouro colapsaram" ;; *) ok "erro comum NÃO vira spawn_timeout:" ;; esac

# ── 5. gc simulado por função (o jeito dos outros selftests do gate) ─────────
echo "── 5. gc como função de shell passa direto ──"
OUT="$(bash -c '
  source "'"$LIB"'" 2>/dev/null
  gc() { printf "{\"session_id\":\"sess-fn\"}"; }
  gate_bounded_spawn gc --city t session new gate-reviewer
')"
eq "a função é chamada e o stdout volta" "$OUT" '{"session_id":"sess-fn"}'
OUT="$(bash -c '
  source "'"$LIB"'" 2>/dev/null
  gc() { echo "invalid connection" >&2; return 1; }
  gate_bounded_spawn gc --city t session new gate-reviewer 2>/dev/null; echo "rc=$?"
')"
eq "o rc da função é preservado" "$OUT" "rc=1"
eq "sem comando algum devolve 127 (não roda nada)" "$(bash -c 'source "'"$LIB"'" 2>/dev/null; gate_bounded_spawn; echo $?')" "127"

# ── 6. sem timeout/gtimeout ──────────────────────────────────────────────────
echo "── 6. sem timeout no PATH → roda SEM teto e avisa ──"
d="$TMP/notimeout"; mkdir -p "$d/bin"; cp "$STUBS/gc-ok" "$d/bin/gc"
NT_OUT="$(PATH="$d/bin:/usr/bin:/bin" bash -c '
  command -v timeout >/dev/null 2>&1 && { echo SKIP-has-timeout; exit 0; }
  command -v gtimeout >/dev/null 2>&1 && { echo SKIP-has-gtimeout; exit 0; }
  source "'"$LIB"'" 2>"'"$d"'/src.err"
  out=$(gate_bounded_spawn gc --city t session new x); echo "rc=$? out=$out"; echo "WARN=$(cat "'"$d"'/src.err")"
')"
case "$NT_OUT" in
  SKIP-*) ok "SKIP: este host tem timeout em /usr/bin ou /bin ($NT_OUT) — cenário não reproduzível aqui" ;;
  *)
    case "$NT_OUT" in *'rc=0 out={"session_id":"sess-ok"'*) ok "o spawn ainda roda (sem teto) quando não há timeout" ;; *) bad "sem timeout o spawn quebrou: $NT_OUT" ;; esac
    case "$NT_OUT" in *"SEM teto"*) ok "o aviso de 'sem teto' sai no carregamento" ;; *) bad "sem aviso de falta do timeout: $NT_OUT" ;; esac
    ;;
esac

# ── 7. classificação ─────────────────────────────────────────────────────────
echo "── 7. is_transient_spawn_error do gate casa o marcador da lib ──"
MARK="spawn_timeout:"
# o texto que a lib ESCREVE (o echo) e o que ela e o gate PROCURAM têm de ser o mesmo literal
if grep -qF "echo \"$MARK '\$1 ...'" "$LIB"; then ok "a lib escreve a linha começando por $MARK"; else bad "a lib não escreve $MARK no stderr"; fi
if grep -qF '*"'"$MARK"'"*) printf '"'1'" "$LIB"; then ok "gate_spawn_err_is_timeout procura o mesmo literal ($MARK)"; else bad "gate_spawn_err_is_timeout não procura $MARK"; fi
if grep -qF '*"'"$MARK"'"*' "$GATE"; then ok "o dispatcher casa o mesmo texto literal ($MARK) em is_transient_spawn_error"; else bad "is_transient_spawn_error não casa $MARK — lib e gate divergiram"; fi
# a armadilha do padrão vazio: função exportada num bash filho SEM as variáveis da lib (as atribuições da lib são
# variáveis de shell, não exportadas — só a função atravessa o `export -f`)
ENVLESS="$(bash -c 'source "'"$LIB"'" 2>/dev/null; export -f gate_spawn_err_is_timeout; bash -c "gate_spawn_err_is_timeout \"invalid connection\"; gate_spawn_err_is_timeout \"spawn_timeout: x\""')"
eq "função exportada sem as variáveis da lib: erro comum=0, timeout=1 (um padrão vazio casaria tudo)" "$ENVLESS" "01"
GATE_FN="$(sed -n '/^is_transient_spawn_error() {/,/^}/p' "$GATE")"
CLS="$(bash -c "$GATE_FN"'; is_transient_spawn_error "spawn_timeout: gc passou de 150s (exit=124)"; is_transient_spawn_error "template not found"; is_transient_spawn_error ""')"
eq "timeout=1 (requeue entre varreduras), erro não transitório=0, vazio=0" "$CLS" "100"
case "$MARK" in *"i/o timeout"*|*"invalid connection"*) bad "o marcador contém um texto que o classificador já casa por outro motivo" ;; *) ok "o marcador não depende de nenhum dos outros padrões transitórios" ;; esac

# ── 8. o laço de retry em processo não repete um timeout ─────────────────────
echo "── 8. spawn-retry-loop não repete um spawn que estourou o teto ──"
RETRY_BLOCK="$(sed -n '/# SELFTEST-EXTRACT spawn-retry-loop: BEGIN/,/# SELFTEST-EXTRACT spawn-retry-loop: END/p' "$GATE")"
if [ -z "$RETRY_BLOCK" ]; then bad "bloco spawn-retry-loop não encontrado no dispatcher"; else
  CAPT_FN="$(sed -n '/^capture_spawn_err_tail() {/,/^}/p' "$GATE")"
  run_loop() {  # $1 = spawn_err inicial; imprime GC_CALLS
    bash -c '
      '"$GATE_FN"'
      '"$CAPT_FN"'
      source "'"$LIB"'" 2>/dev/null
      CALL_LOG=$(mktemp)
      gc() { echo x >> "$CALL_LOG"; echo "invalid connection" >&2; return 1; }
      sleep() { :; }
      warn() { :; }
      gate_spawn_wait_dolt_ready() { :; }
      i=1; BRANCH="fix/x"; GC_CITY="test-city"
      SESSION_ID=""; _spawn_err="$1"
      GATE_SPAWN_RETRY_MAX=3; GATE_SPAWN_RETRY_BACKOFF_SECS=0
      '"$RETRY_BLOCK"'
      printf "GC_CALLS=%s" "$(wc -l < "$CALL_LOG" | tr -d "[:space:]")"; rm -f "$CALL_LOG"
    ' _ "$1" 2>/dev/null
  }
  eq "spawn_timeout: → ZERO retries em processo (a sessão pode já existir)" "$(run_loop 'spawn_timeout: gc passou de 150s (exit=124)')" "GC_CALLS=0"
  eq "controle: 'invalid connection' ainda é repetido até GATE_SPAWN_RETRY_MAX" "$(run_loop 'invalid connection')" "GC_CALLS=3"
fi

# ── 9. fiação: nenhuma chamada nua ───────────────────────────────────────────
echo "── 9. toda chamada 'gc ... session new' dos dispatchers passa por gate_bounded_spawn ──"
bare() { grep -nE 'gc[[:space:]]+--city[[:space:]]+"?\$\{?GC_CITY\}?"?[[:space:]]+session[[:space:]]+new' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'gate_bounded_spawn' || true; }
wrapped() { grep -cE 'gate_bounded_spawn[[:space:]]+gc[[:space:]]+--city[[:space:]]+"\$GC_CITY"[[:space:]]+session[[:space:]]+new' "$1" || true; }
B_GATE="$(bare "$GATE")"; B_REF="$(bare "$REFINO")"
eq "quality-gate-dispatcher: nenhuma chamada sem o teto" "${B_GATE:-none}" "none"
eq "refino-gate-dispatcher: nenhuma chamada sem o teto" "${B_REF:-none}" "none"
# ga-2hd02v.1.9: +2 = o spawn do nó (gate-reviewer-remote) na re-convocação e no Step 7; os 3 locais seguem como estavam.
eq "quality-gate-dispatcher: 5 spawns de reviewer com teto (re-convocação local+nó, inicial local+nó, retry)" "$(wrapped "$GATE")" "5"
eq "refino-gate-dispatcher: 1 spawn de reviewer com teto" "$(wrapped "$REFINO")" "1"
for f in "$GATE" "$REFINO"; do
  if grep -qF 'session-new-bounded.lib.sh' "$f"; then ok "$(basename "$f") carrega a lib"; else bad "$(basename "$f") não carrega session-new-bounded.lib.sh"; fi
  if grep -qE 'gate_bounded_spawn\(\) \{ "\$@"; \}' "$f"; then ok "$(basename "$f") tem o fallback de lib ausente (passagem direta)"; else bad "$(basename "$f") sem fallback para lib ausente — um arquivo faltando derrubaria todo spawn"; fi
done

# ── 10. refino-gate: heartbeat ───────────────────────────────────────────────
echo "── 10. refino-gate carimba o heartbeat que o watchdog lê ──"
HB_NAME="refino-gate-dispatcher.heartbeat"
grep -qF "RG_HB_FILE=\"\$LOG_DIR/$HB_NAME\"" "$REFINO" && ok "RG_HB_FILE aponta para $HB_NAME" || bad "RG_HB_FILE não definido como $HB_NAME"
for fn in log warn err; do
  if grep -E "^$fn\(\)[[:space:]]" "$REFINO" | grep -q '_refino_hb'; then ok "$fn() carimba o heartbeat"; else bad "$fn() não carimba o heartbeat"; fi
done
LOOP_HEAD="$(grep -A8 'while \[ "\$(date +%s)" -lt "\$DEADLINE" \]; do' "$REFINO" | head -9)"
case "$LOOP_HEAD" in *_refino_hb*) ok "o laço de espera do veredito carimba a cada volta (revisão saudável de 20 min não envelhece)" ;; *) bad "o laço de espera não carimba o heartbeat — o watchdog mataria uma revisão saudável" ;; esac
# comportamento real: as três funções + o carimbo, num bash isolado
HBDIR="$TMP/hb"; mkdir -p "$HBDIR"
BEH="$(bash -c '
  LOG_DIR="'"$HBDIR"'"; LOG="'"$HBDIR"'/x.log"; RG_HB_FILE="$LOG_DIR/'"$HB_NAME"'"
  '"$(grep -E '^(ts\(\)|_refino_hb\(\)|log\(\)|warn\(\)|err\(\))' "$REFINO")"'
  [ -e "$RG_HB_FILE" ] && echo pre-existe
  log a; [ -e "$RG_HB_FILE" ] && echo log-carimbou
  rm -f "$RG_HB_FILE"; warn b; [ -e "$RG_HB_FILE" ] && echo warn-carimbou
  rm -f "$RG_HB_FILE"; err c; [ -e "$RG_HB_FILE" ] && echo err-carimbou
  RG_HB_FILE="/nonexistent-dir/hb"; log d; echo "sem-diretorio-nao-abortou rc=$?"
' 2>/dev/null | tr '\n' ' ')"
case "$BEH" in *"log-carimbou"*"warn-carimbou"*"err-carimbou"*"sem-diretorio-nao-abortou rc=0"*) ok "log/warn/err criam o arquivo, e falhar ao gravar não derruba o dispatcher" ;; *) bad "comportamento do heartbeat inesperado: $BEH" ;; esac
if [ -r "$DPW" ] && grep -qF "$HB_NAME" "$DPW"; then ok "o watchdog lê $HB_NAME"; else bad "o watchdog não menciona $HB_NAME ($DPW)"; fi

echo ""
echo "session-new-bounded selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
