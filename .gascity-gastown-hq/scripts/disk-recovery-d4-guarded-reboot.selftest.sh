#!/bin/bash
# disk-recovery-d4-guarded-reboot.selftest.sh — prova do D4 (ga-1p1i5jr.4) com SHUTDOWN SIMULADO. Nunca reinicia nada de verdade.
#
# ## Contents
#   O que prova · Como não reinicia · Filtro de cenários
#
# O QUE PROVA: o reinício só acontece com TODAS as guardas "ok", e "não consegui ler" (3º estado) NUNCA reinicia (disco, estado, pré-checagem,
#   cada guarda, a extração do código do reinício noturno); o aviso sai ANTES do pedido e com entrega CONFIRMADA (push falho → mail; os dois falhos
#   ou prazo estourado → não reinicia; escalada e carimbos de "já avisei" só com entrega confirmada); a marca do reinício está NO DISCO antes do pedido; as guardas
#   são relidas depois da carência; cooldown de 6 h, teto de 2 por 24 h, mini no ar há < 2 h, espera de 10 min; pedido que falha ou que não derruba
#   o mini desfaz a marca e sai 20; UMA linha no stdout; dry-run não escreve nem avisa. A guarda de ligação é um STUB na maioria dos cenários (o código do
#   leitor tem selftest próprio: disk-recovery-d4-calls-in-flight.selftest.sh); a seção "leitor REAL" (ga-1p1i5jr.4.2) roda o D4 contra o leitor de
#   verdade e bancos WAL de mentira, e cobre ainda: pré-checagem (textos novos, erros estranhos, dry-run), bordas do estado e do cooldown, número
#   ruim em DR4_* e sentinela DUPLICADA no reinício noturno.
# COMO NÃO REINICIA: o D4 só chama DR4_REBOOT_CMD (um stub que anota e, no cenário "o mini cai", mata o próprio D4 como o desligamento mata) ou
#   DR4_OSASCRIPT_BIN (outro stub); DR4_NO_REAL_REBOOT=1 vale em TODOS os cenários: se uma costura sumir, o comando de verdade é recusado.
# FILTRO: D4_ST_ONLY='^cool$|^cap$' roda só esses cenários; DR4_ST_SUT aponta outra cópia do D4 (a bateria de mutantes usa os dois).
set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
SUT="${DR4_ST_SUT:-$D/disk-recovery-d4-guarded-reboot.sh}"
NIGHTLY_REAL="${DR4_ST_NIGHTLY:-$D/nightly-reboot.sh}"
ONLY="${D4_ST_ONLY:-}"
SKIP=0
T=$(mktemp -d "${TMPDIR:-/tmp}/d4-selftest.XXXXXX") || { echo "FAIL: sem diretório temporário"; exit 1; }
trap 'rm -rf "$T" 2>/dev/null' EXIT

PASS=0; FAIL=0
check() {  # $1=descrição; resto = comando de teste (palavras, sem && nem !)
  local d=$1; shift
  [ "$SKIP" = 1 ] && return 0
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $d"; fi
}
chk() {  # $1=descrição; $2=expressão de shell (eval) — para && || ! e $(...) avaliados na hora
  local d=$1; shift
  [ "$SKIP" = 1 ] && return 0
  if eval "$*"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $d"; fi
}
section() { echo "== $*"; }

NOW=1800000000
BOOT=$(( NOW - 90000 ))      # no ar há 25 h
NOWH=$(date +%Y-%m-%dT%H:%M:%S)
REALBOOT=$(( $(date +%s) - 100000 ))

# ── um cenário = um diretório com stubs e um vetor de ambiente ──────────────────────────────────────────────────────────────────
ENVV=()
setenv() { ENVV+=("$1"); }   # o último valor de uma variável vence no `env`
stub() {  # $1=nome $2=conteúdo do script em $C/bin (cenário pulado pelo filtro não tem $C/bin)
  [ "$SKIP" = 1 ] && return 0
  printf '#!/bin/bash\n%s\n' "$2" > "$C/bin/$1"; chmod +x "$C/bin/$1"
}
mk_case() {  # $1=nome → C=$T/<nome> com stubs "tudo ok" e o vetor ENVV
  SKIP=0
  if [ -n "$ONLY" ] && ! printf '%s' "$1" | grep -Eq "$ONLY"; then
    SKIP=1; C="$T/skip"; mkdir -p "$C/rodadas"; : > "$C/notify.log"; : > "$C/gc.log"; : > "$C/reboot.calls"; ENVV=(x=1); return 0
  fi
  C="$T/$1"; rm -rf "$C"; mkdir -p "$C/bin" "$C/city/.gc/logs" "$C/rodadas"
  : > "$C/notify.log"; : > "$C/gc.log"; : > "$C/reboot.calls"
  printf 'FileVault is Off.\n' > "$C/fdesetup.out"; echo 0 > "$C/fdesetup.rc"
  printf 'athos\n' > "$C/autologin.out"; echo 0 > "$C/autologin.rc"
  echo 0 > "$C/launchctl.rc"; echo 1 > "$C/pgrep.rc"; : > "$C/pgrep.out"
  echo 0 > "$C/sender.rc"; echo "central_sender_restart_safe: fila sem envio em voo — pode reiniciar" > "$C/sender.out"
  printf 'ok\tpix: nenhuma ligação em curso; voicebot: nenhuma ligação em curso\n' > "$C/calls.out"; echo 0 > "$C/calls.rc"
  echo 0 > "$C/reboot.rc"; echo 5000000 > "$C/df.kb"; echo 0 > "$C/notify.rc"; echo 0 > "$C/gc.rc"; : > "$C/notify.env"
  stub notify "echo \"\$*\" >> $C/notify.log; env | grep -E '^NOTIFY_STRICT_EXIT=' >> $C/notify.env; [ -f $C/notify.hook ] && bash $C/notify.hook \"\$*\"; exit \$(cat $C/notify.rc)"
  stub gc "echo \"\$*\" >> $C/gc.log; exit \$(cat $C/gc.rc)"
  stub fdesetup "cat $C/fdesetup.out; exit \$(cat $C/fdesetup.rc)"
  stub defaults "cat $C/autologin.out; exit \$(cat $C/autologin.rc)"
  stub launchctl "echo 'gui/501/x = { state = not running }'; exit \$(cat $C/launchctl.rc)"
  stub pgrep "cat $C/pgrep.out; exit \$(cat $C/pgrep.rc)"
  stub sysctl "echo 'total = 6144.00M  used = 4096.00M  free = 2048.00M  (encrypted)'"
  stub df "echo 'Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on'; echo \"/dev/disk2s5 239362496 202389956 \$(cat $C/df.kb) 98% 1 1 1% /System/Volumes/Data\""
  stub osascript "echo \"\$@\" > $C/osascript.args; env | grep -E '^(LANG|LC_ALL)=' > $C/osascript.env"
  # o desligamento de verdade TERMina o D4: o stub faz o mesmo quando o cenário pede "o mini cai"; antes anota o estado e os avisos que JÁ existiam
  stub reboot-stub "echo called >> $C/reboot.calls; cp $C/state $C/state.at-reboot 2>/dev/null; cp $C/notify.log $C/notify.at-reboot; env | grep -E '^(LANG|LC_ALL)=' > $C/reboot.env
[ -f $C/reboot.dies ] && { kill -TERM \"\$(cat $C/state.lock.d/pid)\"; sleep 2; }
exit \$(cat $C/reboot.rc)"
  printf 'import sys\nsys.stdout.write(open("%s/sender.out").read())\nsys.exit(int(open("%s/sender.rc").read()))\n' "$C" "$C" > "$C/sender_stub.py"
  printf 'import sys\nsys.stdout.write(open("%s/calls.out").read())\nsys.exit(int(open("%s/calls.rc").read()))\n' "$C" "$C" > "$C/calls_stub.py"
  ENVV=(
    "DR_CITY=$C/city" "DR4_STATE=$C/state" "DR4_LOG=$C/log" "DR_OFF_FILE=$C/off"
    "DR_NOTIFY_BIN=$C/bin/notify" "DR_GC_BIN=$C/bin/gc"
    "DR4_NOW=$NOW" "DR4_BOOT_EPOCH=$BOOT" "DR4_FREE_MB_OVERRIDE=2000" "DR4_CONSOLE_USER=athos"
    "DR4_FDESETUP_BIN=$C/bin/fdesetup" "DR4_DEFAULTS_BIN=$C/bin/defaults" "DR4_LAUNCHCTL_BIN=$C/bin/launchctl"
    "DR4_PGREP_BIN=$C/bin/pgrep" "DR4_SYSCTL_BIN=$C/bin/sysctl" "DR4_DF_BIN=$C/bin/df" "DR4_OSASCRIPT_BIN=$C/bin/osascript"
    "DR4_SENDER_SAFE_PY=$C/sender_stub.py" "DR4_CALLS_PY=$C/calls_stub.py" "DR4_NIGHTLY=$NIGHTLY_REAL"
    "SCRAPER_RODADA_DIR=$C/rodadas" "SCRAPER_BOOT_EPOCH=$REALBOOT"
    "DR4_REBOOT_CMD=$C/bin/reboot-stub" "DR4_NO_REAL_REBOOT=1"
    "DR4_GRACE_S=0" "DR4_WAIT_S=1" "DR4_REBOOT_TIMEOUT_S=15" "DR4_GUARD_TIMEOUT_S=30" "DR4_NOTIFY_TIMEOUT_S=10" "DR4_MAIL_TIMEOUT_S=10"
  )
}
run_sut() {  # args do D4 → RC, OUT, NL (linhas no stdout)
  if [ "$SKIP" = 1 ]; then RC=0; OUT=""; NL=1; return 0; fi
  # sem LANG/LC_ALL herdados: sob launchd não há locale, e o teste do "LANG UTF-8 explícito" só vale se o ambiente do teste também não tiver
  env -u LANG -u LC_ALL "${ENVV[@]}" bash "$SUT" "$@" > "$C/stdout.last" 2> "$C/stderr.last"; RC=$?
  OUT=$(cat "$C/stdout.last"); NL=$(wc -l < "$C/stdout.last" | tr -d ' ')
}
n_reboot() { wc -l < "$C/reboot.calls" | tr -d ' '; }
n_notify() { wc -l < "$C/notify.log" | tr -d ' '; }
n_mail()   { grep -c 'mail send' "$C/gc.log"; }
state_has() { [ -f "$C/state" ] && grep -q "$1" "$C/state"; }
contains() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
one_line() { [ "$NL" = 1 ]; }
no_reboot() { [ "$(n_reboot)" = 0 ]; }
saved_state() { printf 'v=1\nreboots=%s\ndefer_until=%s\ndefer_notify_ts=0\nesc_for=0\n' "$1" "${2:-0}" > "$C/state"; }

expect_no_reboot() {  # $1=desc $2=rc [$3=trecho]: rc certo + UMA linha + nenhum pedido de reinício
  check "$1: rc=$2 (veio $RC: $OUT)" [ "$RC" = "$2" ]
  check "$1: uma linha no stdout (veio $NL)" one_line
  check "$1: NÃO pediu reinício" no_reboot
  [ -z "${3:-}" ] || check "$1: stdout cita '$3' (veio: $OUT)" contains "$3"
}

# ── fixtures do leitor REAL (ga-1p1i5jr.4.2): bancos sqlite em WAL, mesmo molde do selftest do leitor; "estado@minutos-atrás" por linha ──
CALLS_REAL="${DR4_ST_CALLS:-$D/disk-recovery-d4-calls-in-flight.py}"
cat > "$T/mkfix.py" <<'PYEOF'
import sqlite3, sys
kind, path, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
con = sqlite3.connect(path)
con.execute("PRAGMA journal_mode=WAL")
if kind == "pix":
    con.execute("CREATE TABLE pix_call_log (id INTEGER PRIMARY KEY, call_id TEXT, state TEXT, started_at TEXT, ended_at TEXT, updated_at TEXT)")
    table, col = "pix_call_log", "state"
else:
    con.execute("CREATE TABLE voicebot_call_log (id INTEGER PRIMARY KEY, call_id TEXT, status TEXT, started_at TEXT, updated_at TEXT)")
    table, col = "voicebot_call_log", "status"
for i, r in enumerate(rows):
    state, _, age = r.partition("@")
    con.execute("INSERT INTO %s (call_id, %s, started_at) VALUES (?, ?, datetime('now','localtime','-%d minutes'))" % (table, col, int(age)), ("c%d" % i, state))
con.commit(); con.close()
PYEOF
real_calls() {  # depois do mk_case: troca o STUB do leitor pelo leitor REAL e cria os dois bancos em $C. $1/$2 = linhas do pix/voicebot ("dialing@3 bridged@30"); omitido = banco vazio
  [ "$SKIP" = 1 ] && return 0
  /usr/bin/python3 -I "$T/mkfix.py" pix "$C/pix.db" ${1:-}; /usr/bin/python3 -I "$T/mkfix.py" vb "$C/vb.db" ${2:-}
  # o banco de produção é WAL SEM -wal/-shm (os apps abrem e fecham a cada operação) e é esse estado que fez `mode=ro` falhar 34 vezes em 40; o python do
  # sistema deixa os dois, vazios (já checkpointados), ao fechar: tirá-los não perde linha (o ri_pix prova, ele precisa ainda ver a linha)
  rm -f "$C/pix.db-wal" "$C/pix.db-shm" "$C/vb.db-wal" "$C/vb.db-shm"
  setenv "DR4_CALLS_PY=$CALLS_REAL"; setenv "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db"; setenv "VOICEBOT_COST_DB=$C/vb.db"
}
dup_block() {  # $1=NOME da sentinela do nightly → cópia do nightly com o bloco $1-START..$1-END DUPLICADO; aponta o D4 para ela
  [ "$SKIP" = 1 ] && return 0
  { cat "$NIGHTLY_REAL"; sed -n "/$1-START/,/$1-END/p" "$NIGHTLY_REAL"; } > "$C/nightly-dup.sh"; setenv "DR4_NIGHTLY=$C/nightly-dup.sh"
}

# ═══ uso, dry-run, reinício de verdade ═════════════════════════════════════════════════════════════════════════════════════════
section "uso"
mk_case uso
run_sut;                 check "sem argumento: rc 2" [ "$RC" = 2 ]
run_sut --run --dry-run; check "dois modos: rc 2" [ "$RC" = 2 ]
check "uso: nada foi reiniciado" no_reboot

section "dry-run feliz (usa o código REAL do nightly-reboot.sh para o scraper e o Dolt)"
mk_case dry
run_sut --dry-run
check "dry-run: rc 0 (veio $RC: $OUT)" [ "$RC" = 0 ]
check "dry-run: uma linha" one_line
check "dry-run: reiniciaria" contains "reiniciaria agora"
check "dry-run: as 4 guardas leram ok" contains "calls=ok · sender=ok · dolt=ok · scraper=ok"
chk "dry-run: não reiniciou, não escreveu estado, não avisou, não deixou trava" 'no_reboot && [ ! -e "$C/state" ] && [ "$(n_notify)" = 0 ] && [ "$(n_mail)" = 0 ] && [ ! -e "$C/state.lock.d" ]'

section "run feliz: o mini 'cai' (o stub mata o D4 como o desligamento)"
mk_case run_ok; touch "$C/reboot.dies"
run_sut --run
check "run: o D4 morreu por TERM (rc 143; veio $RC)" [ "$RC" = 143 ]
check "run: pediu o reinício UMA vez" [ "$(n_reboot)" = 1 ]
check "run: a marca do reinício JÁ estava no disco quando o pedido saiu" grep -q "reboots=$NOW" "$C/state.at-reboot"
check "run: o aviso (-p 5) saiu ANTES do pedido" grep -q -- "-p 5 -t Disco: reiniciando o mini" "$C/notify.at-reboot"
check "run: o aviso diz como abortar" grep -q "touch $C/off" "$C/notify.at-reboot"
check "run: LANG UTF-8 foi passado ao comando de reinício" grep -q "LANG=en_US.UTF-8" "$C/reboot.env"
chk "run: a marca ficou no estado, a trava foi solta e não houve linha no stdout" 'state_has "reboots=$NOW" && [ ! -e "$C/state.lock.d" ] && [ "$NL" = 0 ]'

section "o comando de VERDADE é osascript→loginwindow aevtrrst, e só sem DR4_REBOOT_CMD"
mk_case osa; setenv "DR4_REBOOT_CMD="; setenv "DR4_NO_REAL_REBOOT=0"
run_sut --run
chk "osascript: chamado com o evento de reinício (veio: $(cat "$C/osascript.args" 2>/dev/null))" 'grep -q loginwindow "$C/osascript.args" && grep -q aevtrrst "$C/osascript.args"'
check "osascript: LANG UTF-8 explícito" grep -q "LANG=en_US.UTF-8" "$C/osascript.env"
check "osascript aceito mas o mini não caiu: rc 20" [ "$RC" = 20 ]
mk_case norl; setenv "DR4_REBOOT_CMD="
run_sut --run
check "NO_REAL_REBOOT sem stub: rc 20 (veio $RC)" [ "$RC" = 20 ]
chk "NO_REAL_REBOOT sem stub: osascript NÃO foi chamado e a marca foi desfeita" '[ ! -e "$C/osascript.args" ] && ! state_has "reboots=$NOW"'

section "o pedido estoura o prazo: não sei se pegou"
mk_case rb_to; setenv "DR4_REBOOT_CMD=sleep 5"; setenv "DR4_REBOOT_TIMEOUT_S=1"
run_sut --run
chk "pedido que estoura o prazo espera como se tivesse pegado (não 'falhou'; veio $RC: $OUT)" '[ "$RC" = 20 ] && contains "continuou no ar" && ! contains "falhou" && contains "não sei se pegou" && ! contains "aceito (rc 0)" && state_has "pending_mark=$NOW"'

section "o pedido falha / não derruba o mini"
mk_case rb_fail; echo 1 > "$C/reboot.rc"
run_sut --run
check "pedido com erro: rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
check "pedido com erro: uma linha" one_line
chk "pedido com erro: desfez a marca e guardou a espera de 30 min" '! state_has "reboots=$NOW" && state_has "defer_until=$((NOW + 1800))"'
check "pedido com erro: avisou que FALHOU" grep -q "FALHOU" "$C/notify.log"
setenv "DR4_NOW=$((NOW + 300))"
run_sut --run
chk "5 min depois: rc 10 'adiado até', sem novo pedido (veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "adiado até" && [ "$(n_reboot)" = 1 ]'
setenv "DR4_NOW=$((NOW + 1900))"
run_sut --run
chk "31 min depois: tenta de novo (o stub falha de novo: rc 20, 2 pedidos)" '[ "$RC" = 20 ] && [ "$(n_reboot)" = 2 ]'
mk_case rb_up   # reboot.rc 0 e o stub não mata ninguém
run_sut --run
check "mini vivo depois do pedido: rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
check "mini vivo depois do pedido: uma linha" one_line
chk "mini vivo depois do pedido: diz que NÃO reiniciou (até agora), MANTÉM a marca como PENDENTE com o boot de referência e a espera de 30 min, e avisou (ga-1p1i5jr.4.3: antes soltava a marca)" 'contains "NÃO reiniciou" && contains "PENDENTE" && contains "aceito (rc 0)" && state_has "reboots=$NOW" && state_has "pending_mark=$NOW" && state_has "pending_boot=$BOOT" && state_has "defer_until=$((NOW + 1800))" && grep -q "NÃO caiu" "$C/notify.log"'

section "o AVISO não saiu: sem aviso CONFIRMADO não reinicia, e ninguém carimba 'já avisei' sem entrega (gate ga-24wp723)"
mk_case nt_ok; touch "$C/reboot.dies"; run_sut --run
check "o notify roda com NOTIFY_STRICT_EXIT=1 (sem ele rc 0 não prova entrega)" grep -q "NOTIFY_STRICT_EXIT=1" "$C/notify.env"
mk_case nt_fail; echo 1 > "$C/notify.rc"; touch "$C/reboot.dies"; run_sut --run
chk "push falhou e o mail ao Mayor saiu: reinicia e o log diz 'mail', não 'notify' (veio $RC)" '[ "$RC" = 143 ] && [ "$(n_mail)" = 1 ] && grep -q "aviso entregue por mail" "$C/log" && ! grep -q "aviso entregue por notify" "$C/log"'
mk_case nt_dead; echo 1 > "$C/notify.rc"; echo 1 > "$C/gc.rc"; run_sut --run
expect_no_reboot "push E mail falharam" 30 "não consegui AVISAR"
chk "push E mail falharam: sem marca, espera de 10 min gravada e o log NÃO diz que o aviso saiu" '! state_has "reboots=$NOW" && state_has "defer_until=$((NOW + 600))" && ! grep -q "aviso entregue" "$C/log"'
mk_case nt_to; stub notify "sleep 5"; setenv "DR4_NOTIFY_TIMEOUT_S=1"; echo 1 > "$C/gc.rc"; run_sut --run
expect_no_reboot "push que estoura o prazo (não sei) E mail falho: prazo estourado não é 'entregue'" 30 "não consegui AVISAR"
mk_case esc_dead; saved_state $((NOW - 3600)); echo 1 > "$C/notify.rc"; echo 1 > "$C/gc.rc"; run_sut --run
chk "escalada sem entrega: NÃO grava esc_for e a linha não diz 'escalado' (veio: $OUT)" '[ "$RC" = 10 ] && ! state_has "esc_for=$((NOW - 3600))" && contains "escalada NÃO entregue" && ! contains "(escalado)"'
echo 0 > "$C/gc.rc"; run_sut --run
chk "só o mail voltou: a escalada sai na rodada seguinte e grava esc_for (veio: $OUT)" 'contains "(escalado)" && state_has "esc_for=$((NOW - 3600))"'
mk_case thr_dead; echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 1 envio(s) em voo" > "$C/sender.out"; echo 1 > "$C/notify.rc"; run_sut --run
chk "adiamento cujo push NÃO saiu: não carimba defer_notify_ts (veio $RC)" '[ "$RC" = 10 ] && state_has "defer_notify_ts=0"'
mk_case re_dead; echo "echo 1 > '$C/sender.rc'; echo 'central_sender_restart_safe: 1 envio(s) em voo' > '$C/sender.out'" > "$C/notify.hook"; echo 1 > "$C/notify.rc"; run_sut --run
chk "cancelamento na releitura cujo push NÃO saiu: não carimba defer_notify_ts (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot && state_has "defer_notify_ts=0"'

# ═══ disco, interruptor ═════════════════════════════════════════════════════════════════════════════════════════════════════════
section "disco"
mk_case disk_ok;   setenv "DR4_FREE_MB_OVERRIDE=3500"
run_sut --run;  expect_no_reboot "disco recuperou" 10 "recuperou"
check "disco recuperou: sem aviso" [ "$(n_notify)" = 0 ]
mk_case disk_edge; setenv "DR4_FREE_MB_OVERRIDE=3072"
run_sut --run;  expect_no_reboot "disco == limiar (>= recupera)" 10 "recuperou"
check "disco == limiar: SEM aviso de reinício (a releitura da carência não pode ser quem segura)" [ "$(n_notify)" = 0 ]
mk_case disk_bad;  setenv "DR4_FREE_MB_OVERRIDE=abc"
run_sut --run;  expect_no_reboot "disco ilegível" 30 "não consegui ler o disco"
mk_case disk_df;   setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; touch "$C/reboot.dies"
run_sut --run;  check "df do stub: lê 2000 MB e reinicia (kill 143; veio $RC)" [ "$RC" = 143 ]
mk_case disk_df_bad; setenv "DR4_FREE_MB_OVERRIDE="; echo x > "$C/df.kb"
run_sut --run;  expect_no_reboot "df devolve lixo" 30 "não consegui ler o disco"

section "interruptor"
mk_case off; touch "$C/off"
run_sut --run;      expect_no_reboot "interruptor (run)" 10 "interruptor"
run_sut --dry-run;  check "interruptor (dry-run): rc 10" [ "$RC" = 10 ]

# ═══ cooldown, teto diário, uptime, estado ═══════════════════════════════════════════════════════════════════════════════════════
section "cooldown / teto / uptime"
mk_case cool; saved_state $((NOW - 3600))
run_sut --run;  expect_no_reboot "cooldown (1 h atrás)" 10 "cooldown"
chk "cooldown: escalou UMA vez (notify -p 5 + mail ao Mayor) e gravou esc_for" 'grep -q -- "-p 5" "$C/notify.log" && [ "$(n_mail)" = 1 ] && state_has "esc_for=$((NOW - 3600))"'
run_sut --run;  chk "cooldown (2ª rodada): NÃO escala duas vezes pelo mesmo reinício (mail=$(n_mail))" '[ "$RC" = 10 ] && [ "$(n_mail)" = 1 ]'
mk_case cool_dry; saved_state $((NOW - 3600))
run_sut --dry-run; chk "cooldown em dry-run: rc 10, sem aviso e sem mail, e a linha NÃO diz 'escalado'" '[ "$RC" = 10 ] && [ "$(n_notify)" = 0 ] && [ "$(n_mail)" = 0 ] && contains "dry-run: não escalo" && ! contains "(escalado)"'
mk_case cool_edge; saved_state $((NOW - 21600)); touch "$C/reboot.dies"
run_sut --run;  check "cooldown: com exatamente 6 h já pode (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case cap; saved_state "$((NOW - 50000)),$((NOW - 30000))"
run_sut --run;  expect_no_reboot "teto de 2 por 24 h" 10 "teto diário"
check "teto: escalou" [ "$(n_mail)" = 1 ]
mk_case cap_one; saved_state $((NOW - 30000)); touch "$C/reboot.dies"
run_sut --run;  check "1 reinício em 24 h (> 6 h atrás) ainda pode (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case uptime; setenv "DR4_BOOT_EPOCH=$((NOW - 3000))"
run_sut --run;  expect_no_reboot "mini no ar há 50 min" 10 "no ar há"
mk_case uptime_edge; setenv "DR4_BOOT_EPOCH=$((NOW - 7200))"; touch "$C/reboot.dies"
run_sut --run;  check "mini no ar há exatamente 2 h já pode (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]

section "teto e cooldown: bordas (ga-1p1i5jr.4.2)"
mk_case cap_old; saved_state "$((NOW - 100000)),$((NOW - 90000))"; touch "$C/reboot.dies"
run_sut --run;  check "2 reinícios, os dois com mais de 24 h: podem de novo (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
chk "cap_old: a marca nova entra na lista; as velhas (< 7 dias) ficam nela sem contar" 'grep -qx "reboots=$((NOW - 100000)),$((NOW - 90000)),$NOW" "$C/state.at-reboot"'
mk_case cap_edge; saved_state "$((NOW - 86400)),$((NOW - 30000))"
run_sut --run;  expect_no_reboot "marca com EXATAMENTE 24 h ainda conta para o teto" 10 "teto diário"
mk_case cap_edge2; saved_state "$((NOW - 86401)),$((NOW - 30000))"; touch "$C/reboot.dies"
run_sut --run;  check "marca com 24 h + 1 s já não conta (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case fut; saved_state $((NOW + 500))
run_sut --run;  expect_no_reboot "marca no FUTURO (o relógio voltou) conta como cooldown, não é ignorada" 10 "cooldown"
mk_case prune; saved_state $((NOW - 700000)); touch "$C/reboot.dies"
run_sut --run;  chk "marca com mais de 7 dias é podada na gravação (kill 143; lista: $(grep reboots= "$C/state.at-reboot" 2>/dev/null))" '[ "$RC" = 143 ] && grep -qx "reboots=$NOW" "$C/state.at-reboot"'

section "estado ilegível ou ausente"
mk_case st_bad1; echo "reboots=abc" > "$C/state"
run_sut --run;  expect_no_reboot "reboots não numérico" 30 "estado do D4"
mk_case st_new; touch "$C/reboot.dies"
run_sut --run;  check "estado AUSENTE = primeira vez: reinicia (kill 143)" [ "$RC" = 143 ]
mk_case st_ro; mkdir "$C/ro"; chmod 555 "$C/ro"; setenv "DR4_STATE=$C/ro/state"; setenv "DR4_LOCKD=$C/ro.lock.d"
run_sut --run
check "não consegue GRAVAR o estado: rc 20 pela mensagem de gravação, não pela releitura (veio $RC: $OUT)" contains "não consegui gravar o estado"
check "não consegue GRAVAR o estado: rc 20" [ "$RC" = 20 ]
check "não consegue gravar o estado: NÃO pediu o reinício" no_reboot
chmod 755 "$C/ro"

section "estado e boottime: bordas (ga-1p1i5jr.4.2)"
mk_case sx_v2; printf 'v=2\nreboots=\n' > "$C/state"
run_sut --run;  expect_no_reboot "estado de versão desconhecida (v=2)" 30 "versão de estado desconhecida"
mk_case sx_hole; echo "reboots=100,,200" > "$C/state"
run_sut --run;  expect_no_reboot "lista com elemento vazio no meio (100,,200)" 30 "estado do D4"
mk_case sx_trail; echo "reboots=100," > "$C/state"
run_sut --run;  expect_no_reboot "lista que termina em vírgula" 30 "estado do D4"
mk_case sx_lead; echo "reboots=,100" > "$C/state"
run_sut --run;  expect_no_reboot "lista que começa com vírgula" 30 "estado do D4"
mk_case sx_big; echo "reboots=99999999999999" > "$C/state"
run_sut --run;  expect_no_reboot "número gigante (14 dígitos) é ilegível, não aritmética muda (senão virava 'cooldown')" 30 "estado do D4"
mk_case sx_dir; mkdir "$C/state"
run_sut --run;  expect_no_reboot "estado que é um DIRETÓRIO (existe e não é arquivo legível)" 30 "não é um arquivo legível"
for k in defer_until defer_notify_ts esc_for pending_mark pending_boot; do
  mk_case "sx_k_$k"; echo "$k=x1" > "$C/state"
  run_sut --run;  expect_no_reboot "estado com $k não numérico" 30 "$k"
done
mk_case sx_key; printf 'v=1\nreboots=\nfoo=bar\nsem-igual\n' > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "chave desconhecida e linha sem '=' são ignoradas (versão futura do mesmo v=1): reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case sx_nonl; printf 'v=1\nreboots=%s' "$((NOW - 3600))" > "$C/state"
run_sut --run;  expect_no_reboot "última linha SEM quebra de linha também é lida (cooldown de 1 h)" 10 "cooldown"
mk_case bt_bad; setenv "DR4_BOOT_EPOCH=abc"
run_sut --run;  expect_no_reboot "DR4_BOOT_EPOCH ilegível" 30 "quando o mini subiu"
mk_case bt_sys; setenv "DR4_BOOT_EPOCH="
run_sut --run;  expect_no_reboot "kern.boottime ilegível (o sysctl devolve outra coisa): não sei, não 'subiu há pouco'" 30 "quando o mini subiu"
mk_case bt_ok; setenv "DR4_BOOT_EPOCH="; stub sysctl "echo '{ sec = $BOOT, usec = 5 } Mon Oct 31 12:00:00 2026'"; touch "$C/reboot.dies"
run_sut --run;  check "kern.boottime lido do sysctl: reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
chk "kern.boottime: leu o token 'sec', não o 'usec' (log: no ar há 1500 min)" 'grep -q "no ar há 1500 min" "$C/log"'

section "pré-checagem"
mk_case pre_fv;  echo "FileVault is On." > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault ligado" 20 "FileVault"
mk_case pre_fv3; echo 2 > "$C/fdesetup.rc"
run_sut --run;  expect_no_reboot "fdesetup falha (não sei)" 30 "pré-checagem ilegível"
mk_case pre_fv4; printf 'FileVault is Off.\nDeferred enablement appears to be active for user x.\n' > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault 'Off' com habilitação ADIADA (liga no próximo login)" 20 "ADIADA"
mk_case pre_al1; echo 1 > "$C/autologin.rc"; echo "The domain/default pair of (x, autoLoginUser) does not exist" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin não configurado" 20 "autologin"
mk_case pre_al2; echo "outro" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin de outro usuário" 20 "autologin"
mk_case pre_lc1; echo 113 > "$C/launchctl.rc"
run_sut --run;  expect_no_reboot "postcheck não carregado" 20 "postcheck"

section "pré-checagem: o que a 2/3 não cobre (ga-1p1i5jr.4.2)"
mk_case px_fv1; echo "Encryption in progress: Percent completed = 12.5" > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault em cifragem (sem a palavra 'On')" 20 "FileVault"
mk_case px_fv2; echo "FileVault status unknown, call support" > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "fdesetup com texto novo que não reconheço (macOS futuro)" 30 "não reconheço"
mk_case px_fv3; : > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "fdesetup sai 0 SEM texto: vazio não é 'desligado'" 30 "não reconheço"
mk_case px_al1; echo 1 > "$C/autologin.rc"; echo "defaults: permission denied" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "defaults falha por outro motivo que não 'does not exist' (não sei, não 'sem autologin')" 30 "defaults read autoLoginUser falhou"
mk_case px_al2; : > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autoLoginUser vazio (rc 0 sem texto)" 30 "veio vazio"
mk_case px_lc1; echo 1 > "$C/launchctl.rc"
run_sut --run;  expect_no_reboot "launchctl falha com rc 1 e sem 'Could not find service': não sei, não 'não carregado'" 30 "launchctl print"
mk_case px_lc2; stub launchctl "echo 'Could not find service in domain'; exit 1"
run_sut --run;  expect_no_reboot "launchctl com o texto 'Could not find service' mesmo com rc 1 = não carregado" 20 "postcheck"
mk_case px_cu1; setenv "DR4_CONSOLE_USER="; stub stat ""; setenv "DR4_STAT_BIN=$C/bin/stat"
run_sut --run;  expect_no_reboot "usuário do console ilegível (sem DR4_CONSOLE_USER e o stat não devolve nada)" 30 "usuário do console"
mk_case px_cu2; setenv "DR4_CONSOLE_USER="; stub stat "echo athos"; setenv "DR4_STAT_BIN=$C/bin/stat"; touch "$C/reboot.dies"
run_sut --run;  check "usuário do console vindo do stat (controle positivo): reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case px_osa; setenv "DR4_REBOOT_CMD="; setenv "DR4_OSASCRIPT_BIN=$C/bin/nao-existe"
run_sut --run;  expect_no_reboot "sem DR4_REBOOT_CMD e sem osascript: reprova (sem sudo não há outro jeito de pedir)" 20 "pré-checagem reprovou"
check "sem osascript: reprovou ANTES do aviso (nenhum push saiu)" [ "$(n_notify)" = 0 ]
mk_case px_dry1; echo "FileVault is On." > "$C/fdesetup.out"
run_sut --dry-run;  check "pré-checagem também no dry-run: FileVault ligado = rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
chk "dry-run reprovado na pré-checagem: uma linha, sem estado, sem aviso" 'one_line && [ ! -e "$C/state" ] && [ "$(n_notify)" = 0 ]'
mk_case px_dry2; echo 2 > "$C/fdesetup.rc"
run_sut --dry-run;  check "pré-checagem ilegível no dry-run = rc 30 (veio $RC: $OUT)" [ "$RC" = 30 ]

# ═══ guardas ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "guardas bloqueiam (adia 10 min e avisa)"
block_case() {  # $1=nome $2=trecho esperado (a preparação do bloqueio é feita antes)
  run_sut --run
  expect_no_reboot "guarda $1 bloqueia" 10 "$2"
  chk "guarda $1: avisou uma vez (push) e gravou a espera de 10 min, sem marca de reinício" '[ "$(n_notify)" = 1 ] && grep -q -- "-p 5" "$C/notify.log" && state_has "defer_until=$((NOW + 600))" && state_has "reboots=$"'
}
mk_case g_calls; echo 1 > "$C/calls.rc"; printf 'block\tpix: 1 ligação(ões) em curso; voicebot: nenhuma ligação em curso\n' > "$C/calls.out"
block_case "ligação em curso" "calls"
mk_case g_snd;  echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 2 envio(s) em voo — adiando o restart para o proximo ciclo" > "$C/sender.out"
block_case "envio em voo" "sender"
mk_case g_dolt; echo 0 > "$C/pgrep.rc"; echo "4242 bash dolt-compact-routine.sh" > "$C/pgrep.out"
block_case "manutenção do Dolt" "dolt"
mk_case g_scr;  echo "{\"status\":\"running\",\"pid\":$$,\"started_at\":\"$NOWH\",\"rodada_id\":\"r1\",\"phase\":\"scrape\"}" > "$C/rodadas/r1.json"
block_case "rodada do scraper (função REAL do noturno)" "scraper"

section "espera de 10 min, aviso a cada 60 min"
mk_case hold; echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 1 envio(s) em voo" > "$C/sender.out"
run_sut --run;  chk "hold 1ª: rc 10, 1 aviso" '[ "$RC" = 10 ] && [ "$(n_notify)" = 1 ]'
setenv "DR4_NOW=$((NOW + 60))"
run_sut --run;  chk "hold +1min: rc 10 'adiado até', sem reavaliar nem avisar (notify=$(n_notify); veio: $OUT)" '[ "$RC" = 10 ] && contains "adiado até" && [ "$(n_notify)" = 1 ]'
setenv "DR4_NOW=$((NOW + 700))"
run_sut --run;  chk "hold +11min: reavalia e segue bloqueado, aviso SUPRIMIDO (< 60 min; notify=$(n_notify))" '[ "$RC" = 10 ] && contains "guarda(s) bloqueando" && [ "$(n_notify)" = 1 ]'
setenv "DR4_NOW=$((NOW + 3700))"
run_sut --run;  chk "hold +62min: bloqueado de novo e AGORA avisa (notify=$(n_notify))" '[ "$RC" = 10 ] && [ "$(n_notify)" = 2 ]'
echo 0 > "$C/sender.rc"; echo "central_sender_restart_safe: fila sem envio em voo — pode reiniciar" > "$C/sender.out"; touch "$C/reboot.dies"
setenv "DR4_NOW=$((NOW + 7400))"
run_sut --run;  check "guarda liberou: reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case hold_dry; saved_state "" $((NOW + 500))
run_sut --dry-run; chk "dry-run não obedece a espera, só informa (rc 0 + nota; veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "adiado até"'
mk_case g_dry; echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 1 envio(s) em voo" > "$C/sender.out"
run_sut --dry-run
chk "dry-run com guarda bloqueando: rc 10, sem estado, sem aviso, sem mail (veio $RC: $OUT)" '[ "$RC" = 10 ] && [ ! -e "$C/state" ] && [ "$(n_notify)" = 0 ] && [ "$(n_mail)" = 0 ] && no_reboot'
mk_case g_mix; echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 1 envio(s) em voo" > "$C/sender.out"; echo 2 > "$C/pgrep.rc"
run_sut --run;  expect_no_reboot "bloqueio + ilegível: o bloqueio vence" 10 "sem leitura: dolt"

section "guardas ilegíveis nunca reiniciam (rc 30) e avisam"
unk_case() {  # $1=nome $2=trecho (preparo feito antes)
  run_sut --run
  expect_no_reboot "guarda ilegível: $1" 30 "$2"
  check "guarda ilegível $1: avisou (o D4 cego é problema)" [ "$(n_notify)" = 1 ]
}
mk_case u_calls1; setenv "DR4_CALLS_PY=$C/nao-existe.py"
unk_case "leitor de ligações ausente" "não legível"
mk_case u_calls2; echo 2 > "$C/calls.rc"; printf 'unknown\tpix: banco ausente\n' > "$C/calls.out"
unk_case "leitor de ligações devolve unknown (rc 2)" "banco ausente"
mk_case u_calls3; echo 7 > "$C/calls.rc"
unk_case "leitor de ligações com rc estranho" "rc=7"
mk_case u_calls4; echo 1 > "$C/calls.rc"; printf 'Traceback (most recent call last): ValueError\n' > "$C/calls.out"
unk_case "leitor de ligações: rc 1 de TRACEBACK não é 'há ligação'" "rc=1"
mk_case u_snd1; echo 2 > "$C/sender.rc"; echo "central_sender_restart_safe: NAO SEI se ha envio em voo" > "$C/sender.out"
unk_case "envio: NÃO SEI (rc 2)" "sender"
mk_case u_snd2; echo 1 > "$C/sender.rc"; echo "Traceback (most recent call last): ValueError" > "$C/sender.out"
unk_case "envio: rc 1 de TRACEBACK não é 'em voo'" "sem a mensagem do script"
mk_case u_dolt; echo 2 > "$C/pgrep.rc"; echo "pgrep: erro" > "$C/pgrep.out"
unk_case "Dolt: pgrep falha" "pgrep falhou"
mk_case u_scr1; echo "{isso nao e json" > "$C/rodadas/r1.json"
unk_case "scraper: marker ilegível" "scraper"
mk_case u_scr3; sed 's/SCRAPER-DAILY-GUARD-START/SCRAPER-DAILY-GUARD-STARTX/' "$NIGHTLY_REAL" > "$C/nightly-drift.sh"; setenv "DR4_NIGHTLY=$C/nightly-drift.sh"
unk_case "sentinela do scraper mudou (drift)" "sentinela SCRAPER-DAILY-GUARD"
mk_case u_scr5; sed 's/DOLT-MAINT-PATTERN-END/DOLT-MAINT-PATTERN-ENDX/' "$NIGHTLY_REAL" > "$C/nightly-drift2.sh"; setenv "DR4_NIGHTLY=$C/nightly-drift2.sh"
unk_case "sentinela do Dolt mudou (drift)" "sentinela DOLT-MAINT-PATTERN"
mk_case u_scr6; dup_block SCRAPER-DAILY-GUARD
unk_case "sentinela do scraper DUPLICADA (dois blocos: qual vale? não sei)" "sentinela SCRAPER-DAILY-GUARD"
mk_case u_dolt2; dup_block DOLT-MAINT-PATTERN
unk_case "sentinela do Dolt DUPLICADA" "sentinela DOLT-MAINT-PATTERN"
mk_case u_calls5; printf 'Python 3 banner sem estado\n' > "$C/calls.out"
unk_case "leitor sai 0 mas SEM a linha 'ok<TAB>…': rc 0 sozinho não é 'não há ligação'" "rc=0"
mk_case u_nightly; setenv "DR4_NIGHTLY=$C/nao-existe.sh"
unk_case "reinício noturno ausente" "não legível"
chk "reinício noturno ausente: as DUAS guardas que dependem dele dizem 'sem leitura'" 'contains "(dolt, scraper)"'

section "leitor REAL de ligações (ga-1p1i5jr.4.1) com bancos WAL de mentira (ga-1p1i5jr.4.2)"
mk_case ri_ok; real_calls
chk "precondição: os bancos WAL começam SEM -wal/-shm (o estado de produção)" '[ ! -e "$C/pix.db-wal" ] && [ ! -e "$C/pix.db-shm" ] && [ ! -e "$C/vb.db-wal" ] && [ ! -e "$C/vb.db-shm" ]'
run_sut --dry-run
chk "bancos vazios, dry-run: rc 0 e calls=ok (o formato e o --max-age-min do leitor batem com o que o D4 lê, e o WAL sem -wal/-shm abre; veio $RC: $OUT)" '[ "$RC" = 0 ] && one_line && contains "calls=ok"'
mk_case ri_run; real_calls; touch "$C/reboot.dies"
run_sut --run
check "bancos vazios, --run: reinicia (kill 143; a leitura de antes e a de depois da carência passam; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case ri_pix; real_calls "dialing@3"
run_sut --run
expect_no_reboot "pix 'dialing' recente" 10 "pix: 1 ligação(ões) em curso"
chk "pix 'dialing': espera de 10 min gravada, sem marca de reinício, um push" 'state_has "defer_until=$((NOW + 600))" && state_has "reboots=$" && [ "$(n_notify)" = 1 ]'
mk_case ri_vb; real_calls "" "live@2"
run_sut --run;  expect_no_reboot "voicebot 'live' recente" 10 "voicebot: 1 ligação(ões) em curso"
mk_case ri_orph; real_calls "dialing@360"
run_sut --dry-run;  chk "ligação ÓRFÃ (6 h, acima do corte padrão de 4 h) não segura (veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "calls=ok"'
mk_case ri_age1; real_calls "dialing@30"
run_sut --dry-run;  chk "controle: a MESMA linha de 30 min com o corte padrão (240) segura (veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "calls"'
mk_case ri_age2; real_calls "dialing@30"; setenv "DR4_CALL_MAX_AGE_MIN=10"
run_sut --dry-run;  chk "DR4_CALL_MAX_AGE_MIN chega ao leitor: com corte de 10 min a linha de 30 vira órfã (veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "calls=ok"'
mk_case ri_nodb; real_calls; rm -f "$C/pix.db"
unk_case "leitor REAL: banco do pix ausente" "banco ausente"
chk "banco ausente: o leitor NÃO o criou" '[ ! -e "$C/pix.db" ]'
mk_case ri_junk; real_calls; echo "isto não é um banco" > "$C/vb.db"
unk_case "leitor REAL: banco do voicebot corrompido" "voicebot"
mk_case ri_mix; real_calls "dialing@1"; rm -f "$C/vb.db"
run_sut --run;  expect_no_reboot "ligação em curso (pix) + banco do voicebot ausente: o bloqueio vence o 'não sei'" 10 "pix: 1 ligação(ões) em curso"
chk "bloqueio + ilegível dentro do MESMO leitor: a guarda é 'block', não 'sem leitura'" '! contains "sem leitura"'
mk_case ri_py; real_calls; setenv "DR4_PYTHON=$C/bin/nao-existe"
unk_case "interpretador do leitor ausente (rc 127)" "rc=127"

section "número ruim em DR4_*: lixo cai no padrão E o log diz (ga-1p1i5jr.4.2)"
mk_case en_mb; setenv "DR4_MB=abc"; touch "$C/reboot.dies"
run_sut --run;  chk "DR4_MB=abc cai no padrão 3072: livre 2000 reinicia (kill 143; veio $RC) e o log diz" '[ "$RC" = 143 ] && grep -q "DR4_MB=.abc.->3072" "$C/log"'
mk_case en_cd; setenv "DR4_COOLDOWN_S=seis"; saved_state $((NOW - 3600))
run_sut --run;  chk "DR4_COOLDOWN_S=seis NÃO vira 'sem cooldown': cai nos 6 h (rc 10; veio $RC: $OUT) e o log diz" '[ "$RC" = 10 ] && contains "cooldown" && no_reboot && grep -q "DR4_COOLDOWN_S=.seis.->21600" "$C/log"'
mk_case en_cap; setenv "DR4_DAY_CAP=1234567890"; saved_state "$((NOW - 50000)),$((NOW - 30000))"
run_sut --run;  chk "DR4_DAY_CAP com 10 dígitos (> 9) cai no padrão 2: o teto segura (rc 10; veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "teto diário" && grep -q "DR4_DAY_CAP=.1234567890.->2" "$C/log"'
mk_case en_ok; setenv "DR4_MB=4096"; setenv "DR4_FREE_MB_OVERRIDE=3500"; touch "$C/reboot.dies"
run_sut --run;  chk "controle: número válido (DR4_MB=4096) vale e o log NÃO reclama (kill 143; veio $RC)" '[ "$RC" = 143 ] && ! grep -q "variável(is) DR4_" "$C/log"'

# ═══ releitura depois da carência, trava ═════════════════════════════════════════════════════════════════════════════════════════
section "releitura depois do aviso: o veredito de minutos atrás não vale"
mk_case re_snd; echo "echo 1 > '$C/sender.rc'; echo 'central_sender_restart_safe: 1 envio(s) em voo' > '$C/sender.out'" > "$C/notify.hook"
run_sut --run
chk "envio começou durante o aviso: rc 10, NÃO pediu reinício, nenhuma marca, grava a espera (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot && ! state_has "reboots=$NOW" && state_has "defer_until=$((NOW + 600))"'
check "envio começou durante o aviso: diz 'cancelado' no aviso" grep -q "cancelado" "$C/notify.log"
mk_case re_off; echo "touch '$C/off'" > "$C/notify.hook"; setenv "DR4_GRACE_S=3"
run_sut --run
chk "interruptor ligado durante a carência: rc 10, não reiniciou, e NÃO grava espera (é um humano mandando calar; o passo 1 o respeita sozinho; veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot && ! state_has "defer_until=[1-9]"'
mk_case re_disk; setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; echo "echo 4096000 > '$C/df.kb'" > "$C/notify.hook"
run_sut --run
chk "disco recuperou durante a carência: rc 10, não reiniciou (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot'
mk_case re_unk; echo "echo 2 > '$C/sender.rc'; echo 'nao sei' > '$C/sender.out'" > "$C/notify.hook"
run_sut --run
chk "guarda ficou ilegível durante a carência: rc 30, não reiniciou (veio $RC: $OUT)" '[ "$RC" = 30 ] && no_reboot'
mk_case re_pos; touch "$C/reboot.dies"
run_sut --run
check "controle positivo: sem mudança durante a carência, reinicia (kill 143)" [ "$RC" = 143 ]

section "instância única"
mk_case lock_live; setenv "DR4_BOOT_EPOCH=$(( $(date +%s) - 100000 ))"; mkdir "$C/state.lock.d"; sleep 30 & LP=$!; echo "$LP" > "$C/state.lock.d/pid"
run_sut --run;  expect_no_reboot "trava com pid vivo" 10 "outra instância"
check "trava viva: a trava de outro NÃO foi tomada" [ -e "$C/state.lock.d/pid" ]
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
mk_case lock_boot; setenv "DR4_BOOT_EPOCH=$(( $(date +%s) + 1000 ))"; mkdir "$C/state.lock.d"; sleep 30 & LP=$!; echo "$LP" > "$C/state.lock.d/pid"; touch "$C/reboot.dies"
run_sut --run;  check "trava com pid VIVO mas criada ANTES do boot atual (pid reaproveitado) é tomada (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
mk_case lock_dead; mkdir "$C/state.lock.d"; echo 99999 > "$C/state.lock.d/pid"; touch "$C/reboot.dies"
run_sut --run;  check "trava com pid MORTO é tomada e o D4 segue (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]

# ═══ ga-1p1i5jr.4.3 — os 3 pontos que o revisor do gate (ga-24wp723) deixou de fora ═════════════════════════════════════════════════
n_warn() { grep -c 'reiniciando o mini em' "$C/notify.log"; }   # avisos "reiniciando em Ns" que saíram (o de cancelamento tem outro título)

section "pedido PENDENTE: o mini não caiu em WAIT_S mas pode cair depois (ga-1p1i5jr.4.3, ponto 1)"
mk_case pd1                                          # rodada 1: pedido aceito, o mini continua no ar
run_sut --run
chk "pd1: rc 20, UMA linha, e a marca FICA no estado como PENDENTE (boot de referência e espera de 30 min; veio $RC: $OUT)" '[ "$RC" = 20 ] && one_line && contains "PENDENTE" && state_has "reboots=$NOW" && state_has "pending_mark=$NOW" && state_has "pending_boot=$BOOT" && state_has "defer_until=$((NOW + 1800))"'
N0=$(n_notify)
setenv "DR4_NOW=$((NOW + 300))"                      # rodada 2: 5 min depois, MESMO boot, dentro da espera
run_sut --run
chk "pd2: pendência dentro da espera: rc 10 'PENDENTE', NÃO pede de novo, NÃO escala (sem mail, sem aviso novo) e a marca segue lá (veio $RC: $OUT)" '[ "$RC" = 10 ] && one_line && contains "PENDENTE" && [ "$(n_reboot)" = 1 ] && [ "$(n_mail)" = 0 ] && [ "$(n_notify)" = "$N0" ] && state_has "reboots=$NOW" && state_has "pending_mark=$NOW"'
setenv "DR4_NOW=$((NOW + 1900))"                     # rodada 3: a espera acabou e o boot é o mesmo → o mini NÃO reiniciou: solta a marca e tenta de novo
run_sut --run
chk "pd3: mesmo boot depois da espera: solta a marca velha, pede de novo (2 pedidos) e a pendência passa para a marca NOVA (veio $RC: $OUT)" '[ "$RC" = 20 ] && [ "$(n_reboot)" = 2 ] && grep -qx "reboots=$((NOW + 1900))" "$C/state" && state_has "pending_mark=$((NOW + 1900))" && grep -q "solto a marca" "$C/log"'

mk_case pd_slow                                      # o desligamento era só LENTO: o mini caiu depois dos WAIT_S e voltou
run_sut --run
setenv "DR4_NOW=$((NOW + 2400))"; setenv "DR4_BOOT_EPOCH=$((NOW + 600))"
run_sut --run
chk "pd_slow: boot mudou: a marca VALE (rc 10 'cooldown'), a escalada sai UMA vez porque o disco segue baixo, sem novo pedido e a pendência é resolvida (veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "cooldown" && [ "$(n_reboot)" = 1 ] && [ "$(n_mail)" = 1 ] && state_has "reboots=$NOW" && state_has "pending_mark=0" && state_has "pending_boot=0" && state_has "esc_for=$NOW"'

# o boottime vale com tolerância (BOOT_TOL_S=300): ajuste curto do relógio não é reinício; reinício de verdade move o boot por >= 2 h
tol_case() {  # $1=nome $2=boot na rodada 2 $3=esperado: same|changed
  mk_case "$1"; run_sut --run
  setenv "DR4_NOW=$((NOW + 1900))"; setenv "DR4_BOOT_EPOCH=$2"; [ "$3" = same ] && touch "$C/reboot.dies"
  run_sut --run
  if [ "$3" = same ]; then
    chk "$1: boot $2 (diferença dentro da tolerância) = MESMO boot: solta a marca e pede de novo (kill 143; veio $RC: $OUT)" '[ "$RC" = 143 ] && [ "$(n_reboot)" = 2 ] && grep -qx "reboots=$((NOW + 1900))" "$C/state.at-reboot" && grep -qx "pending_mark=0" "$C/state.at-reboot"'
  else
    chk "$1: boot $2 (diferença acima da tolerância) = o mini reiniciou: a marca FICA e o cooldown vale (rc 10, sem novo pedido; veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "cooldown" && [ "$(n_reboot)" = 1 ] && state_has "reboots=$NOW" && state_has "pending_mark=0"'
  fi
}
tol_case pd_tol_in   $((BOOT + 120)) same
tol_case pd_tol_edge $((BOOT + 300)) same           # exatamente a tolerância ainda é o mesmo boot
tol_case pd_tol_neg  $((BOOT - 120)) same           # o relógio pode ter andado para trás
tol_case pd_tol_out  $((BOOT + 301)) changed
tol_case pd_tol_far  $((BOOT + 600)) changed
tol_case pd_tol_negf $((BOOT - 600)) changed        # a diferença é em módulo: boot MAIS ANTIGO também é outro boot (relógio saltou: não sei, lado inerte)

mk_case pd_dry; run_sut --run; setenv "DR4_NOW=$((NOW + 300))"; cp "$C/state" "$C/state.before"
run_sut --dry-run
chk "pd_dry: dry-run durante a pendência: rc 0 'reiniciaria', diz PENDENTE, não grava nada (estado idêntico) e não escala (veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "reiniciaria agora" && contains "PENDENTE" && cmp -s "$C/state" "$C/state.before" && [ "$(n_mail)" = 0 ]'
# os dois ramos que RESOLVEM a pendência (boot mudou; espera acabou com o mesmo boot) são os que gravam no --run: no --dry-run nenhum pode gravar (a bateria de mutantes achou o buraco)
mk_case pd_dry_chg; run_sut --run; setenv "DR4_NOW=$((NOW + 2400))"; setenv "DR4_BOOT_EPOCH=$((NOW + 600))"; cp "$C/state" "$C/state.before"
run_sut --dry-run
chk "pd_dry_chg: dry-run com o boot mudado: diz 'cooldown', NÃO grava a pendência resolvida (estado idêntico, pending_mark segue lá) e não pede reinício (veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "cooldown" && cmp -s "$C/state" "$C/state.before" && state_has "pending_mark=$NOW" && [ "$(n_reboot)" = 1 ]'
mk_case pd_dry_exp; run_sut --run; setenv "DR4_NOW=$((NOW + 1900))"; cp "$C/state" "$C/state.before"
run_sut --dry-run
chk "pd_dry_exp: dry-run depois da espera com o mesmo boot: diz 'reiniciaria', NÃO grava a marca solta (estado idêntico, a marca velha segue lá) e não pede reinício (veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "reiniciaria agora" && cmp -s "$C/state" "$C/state.before" && state_has "reboots=$NOW" && state_has "pending_mark=$NOW" && [ "$(n_reboot)" = 1 ]'

mk_case pd_disk; run_sut --run                      # disco que recupera no meio da pendência: "recuperou" vence, e a pendência continua anotada
setenv "DR4_NOW=$((NOW + 300))"; setenv "DR4_FREE_MB_OVERRIDE=3500"
run_sut --run
chk "pd_disk: pendência e disco recuperado: 'recuperou' vence (rc 10) e a pendência segue anotada (veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "recuperou" && state_has "pending_mark=$NOW" && [ "$(n_mail)" = 0 ]'
setenv "DR4_NOW=$((NOW + 2400))"; setenv "DR4_BOOT_EPOCH=$((NOW + 600))"
run_sut --run
chk "pd_disk 2: o mini reiniciou e o disco está bom: a pendência é resolvida MESMO ASSIM (a marca fica, pending_mark=0; veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "recuperou" && state_has "reboots=$NOW" && state_has "pending_mark=0"'

mk_case pd_bad1; printf 'v=1\nreboots=%s\ndefer_until=0\npending_mark=%s\npending_boot=%s\n' "$NOW" "$NOW" "x1" > "$C/state"
run_sut --run;  expect_no_reboot "estado com pending_boot não numérico" 30 "pending_boot"
mk_case pd_bad2; printf 'v=1\nreboots=%s\npending_mark=%s\n' "$NOW" "$NOW" > "$C/state"
run_sut --run;  expect_no_reboot "pending_mark SEM pending_boot (não há com o que conferir: nem 'mudou' nem 'igual')" 30 "sem pending_boot"
mk_case pd_bad3; printf 'v=1\nreboots=%s\npending_mark=%s\npending_boot=0\n' "$NOW" "$NOW" > "$C/state"
run_sut --run;  expect_no_reboot "pending_mark com pending_boot=0" 30 "sem pending_boot"
mk_case pd_orph; printf 'v=1\nreboots=\ndefer_until=0\npending_mark=%s\npending_boot=%s\n' "$((NOW - 3000))" "$BOOT" > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "pendência cuja marca nem está na lista (podada/editada): soltar não quebra, o fluxo segue e reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]

section "pré-checagem DEPOIS da carência: o que ela leu pode ter mudado nos 60 s (ga-1p1i5jr.4.3, ponto 2)"
pc_case() {  # $1=nome $2=comando do hook (muda o mundo durante o aviso; escreva @C@ onde iria o diretório do cenário: $C só existe DEPOIS do mk_case) $3=rc esperado $4=trecho do stdout
  mk_case "$1"; PC_HOOK=${2//@C@/$C}; echo "$PC_HOOK" > "$C/notify.hook"
  run_sut --run
  expect_no_reboot "pré-checagem muda durante a carência ($1)" "$3" "$4"
  chk "$1: sem marca de reinício, espera de 10 min gravada, e o cancelamento foi AVISADO (veio: $OUT)" '! state_has "reboots=$NOW" && state_has "defer_until=$((NOW + 600))" && grep -q "cancelado" "$C/notify.log"'
}
pc_case pc_fv  "echo 'FileVault is On.' > '@C@/fdesetup.out'"             20 "FileVault"
pc_case pc_fv2 "printf 'FileVault is Off.\nDeferred enablement appears to be active for user x.\n' > '@C@/fdesetup.out'" 20 "ADIADA"
pc_case pc_al  "echo outro > '@C@/autologin.out'"                         20 "autologin"
pc_case pc_lc  "echo 113 > '@C@/launchctl.rc'"                            20 "postcheck"
pc_case pc_unk "echo 2 > '@C@/fdesetup.rc'"                               30 "ilegível depois da carência"
pc_case pc_lcx "echo 1 > '@C@/launchctl.rc'"                              30 "ilegível depois da carência"

section "cancelou DEPOIS do aviso: espera de 10 min, o aviso 'reiniciando em Ns' não se repete a cada rodada (ga-1p1i5jr.4.3, ponto 3)"
osc_run() {  # $1=nome $2=rc da 1ª rodada $3=comando que desfaz a mudança do hook; o chamador já fez mk_case, o preparo e o notify.hook
  OSC_RC=$2    # o chk avalia a expressão (eval) dentro da função dele, onde "$2" não existe (set -u): vai por variável
  run_sut --run
  chk "$1: 1ª rodada cancela depois do aviso (rc $2; veio $RC: $OUT): sem pedido, UM aviso 'reiniciando em' e espera de 10 min gravada" '[ "$RC" = "$OSC_RC" ] && no_reboot && [ "$(n_warn)" = 1 ] && state_has "defer_until=$((NOW + 600))" && state_has "pending_mark=0"'
  rm -f "$C/notify.hook"; eval "$3"
  setenv "DR4_NOW=$((NOW + 60))"
  run_sut --run
  chk "$1: 1 min depois, com o mundo normal de novo: NÃO repete o aviso nem pede reinício (rc 10 'adiado até'; veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "adiado até" && no_reboot && [ "$(n_warn)" = 1 ]'
  setenv "DR4_NOW=$((NOW + 700))"
  run_sut --run
  chk "$1: 11 min depois a espera acabou (controle: ela tem fim): avisa DE NOVO e pede o reinício (avisos=$(n_warn), pedidos=$(n_reboot))" '[ "$(n_warn)" = 2 ] && [ "$(n_reboot)" = 1 ]'
}
mk_case osc_disk; setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; echo "echo 4096000 > '$C/df.kb'" > "$C/notify.hook"
osc_run osc_disk 10 "echo 2048000 > '$C/df.kb'"
mk_case osc_rd;   setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; echo "echo x > '$C/df.kb'" > "$C/notify.hook"
osc_run osc_rd 30 "echo 2048000 > '$C/df.kb'"
mk_case osc_pre;  echo "echo 'FileVault is On.' > '$C/fdesetup.out'" > "$C/notify.hook"
osc_run osc_pre 20 "echo 'FileVault is Off.' > '$C/fdesetup.out'"
mk_case osc_unk;  echo "echo 2 > '$C/sender.rc'; echo 'nao sei' > '$C/sender.out'" > "$C/notify.hook"
osc_run osc_unk 30 "echo 0 > '$C/sender.rc'; echo 'central_sender_restart_safe: fila sem envio em voo — pode reiniciar' > '$C/sender.out'"
mk_case osc_blk;  echo "echo 1 > '$C/sender.rc'; echo 'central_sender_restart_safe: 1 envio(s) em voo' > '$C/sender.out'" > "$C/notify.hook"
osc_run osc_blk 10 "echo 0 > '$C/sender.rc'; echo 'central_sender_restart_safe: fila sem envio em voo — pode reiniciar' > '$C/sender.out'"

echo
echo "disk-recovery-d4-guarded-reboot.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
