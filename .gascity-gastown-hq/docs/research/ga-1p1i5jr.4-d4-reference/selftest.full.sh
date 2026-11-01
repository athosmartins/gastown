#!/bin/bash
# disk-recovery-d4-guarded-reboot.selftest.sh — prova do D4 (ga-1p1i5jr.4) com SHUTDOWN SIMULADO. Nunca reinicia nada de verdade.
#
# ## Contents
#   O que prova · Como não reinicia · Cenários
#
# O QUE PROVA (cada item tem um cenário que REPROVA se o item for quebrado — a bateria de mutantes está no comentário do bead):
#   · o reinício só acontece com TODAS as guardas "ok", e "não consegui ler" (3º estado) NUNCA reinicia — em cada guarda, em cada pré-checagem,
#     no disco, no estado e na extração do código do reinício noturno;
#   · aviso (notify) ANTES do pedido; a marca do reinício está NO DISCO e CONFERIDA antes do pedido; as guardas são relidas depois da carência;
#   · cooldown de 6 h, teto de 2 por 24 h, mini no ar há < 2 h, espera de 10 min depois de uma guarda adiar, 30 min depois de um pedido que falhou;
#   · pedido que falha, ou que é aceito e o mini continua no ar, desfaz a marca e sai 20;
#   · UMA linha no stdout; dry-run não escreve estado nem avisa; interruptor; trava de instância única;
#   · o leitor de ligações lê o banco WAL SEM -shm (a falha medida ao vivo: `mode=ro` dava 34 erros em 40) e não altera nem cria banco.
# COMO NÃO REINICIA: o D4 só chama DR4_REBOOT_CMD (um stub que anota e, no cenário do "mini cai", mata o próprio D4 como o desligamento mata),
#   ou DR4_OSASCRIPT_BIN (outro stub). DR4_NO_REAL_REBOOT=1 vale em TODOS os cenários: se uma costura sumir, o comando de verdade é recusado.
set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
SUT="${DR4_ST_SUT:-$D/disk-recovery-d4-guarded-reboot.sh}"
CALLS="${DR4_ST_CALLS:-$D/disk-recovery-d4-calls-in-flight.py}"
ONLY="${D4_ST_ONLY:-}"   # regex de nomes de cenário: só esses rodam (a bateria de mutantes roda 1-2 cenários por mutante)
SKIP=0
NIGHTLY_REAL="${DR4_ST_NIGHTLY:-$D/nightly-reboot.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/d4-selftest.XXXXXX") || { echo "FAIL: sem diretório temporário"; exit 1; }
cleanup() { rm -rf "$T" 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() {  # $1=descrição; resto = comando de teste (palavras, sem && nem !)
  local d=$1; shift
  [ "$SKIP" = 1 ] && return 0
  if "$@"; then pass; else fail "$d"; fi
}
chk() {  # $1=descrição; $2=expressão de shell (eval) — para && || ! e $(...) avaliados na hora
  local d=$1; shift
  [ "$SKIP" = 1 ] && return 0
  if eval "$*"; then pass; else fail "$d"; fi
}
section() { echo "== $*"; }

NOW=1800000000
BOOT=$(( NOW - 90000 ))      # no ar há 25 h
NOWH=$(date +%Y-%m-%dT%H:%M:%S)
REALBOOT=$(( $(date +%s) - 100000 ))

# ── fixtures de banco (python3 do sistema, isolado) ───────────────────────────────────────────────────────────────────────────
cat > "$T/mkfix.py" <<'PYEOF'
import sqlite3, sys
kind, path, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
con = sqlite3.connect(path)
con.execute("PRAGMA journal_mode=WAL")
if kind == "pix":
    con.execute("CREATE TABLE pix_call_log (id INTEGER PRIMARY KEY, call_id TEXT, state TEXT, started_at TEXT, ended_at TEXT, updated_at TEXT)")
    col = "state"; table = "pix_call_log"
elif kind == "vb":
    con.execute("CREATE TABLE voicebot_call_log (id INTEGER PRIMARY KEY, call_id TEXT, status TEXT, started_at TEXT, updated_at TEXT)")
    col = "status"; table = "voicebot_call_log"
elif kind == "vb-notable":
    con.execute("CREATE TABLE outra (x INTEGER)"); rows = []; col = table = None
else:
    raise SystemExit("kind?")
for i, r in enumerate(rows):
    state, _, age = r.partition("@")
    if age in ("", "null"):
        ts = "NULL"
    else:
        ts = "datetime('now','localtime','-%d minutes')" % int(age)
    con.execute("INSERT INTO %s (call_id, %s, started_at) VALUES (?, ?, %s)" % (table, col, ts), ("c%d" % i, state))
con.commit()
con.close()
PYEOF
mkfix() { /usr/bin/python3 -I "$T/mkfix.py" "$@"; }
mkfix pix "$T/pix.empty.db"; mkfix vb "$T/vb.empty.db"

# ── um cenário = um diretório com stubs e um vetor de ambiente ──────────────────────────────────────────────────────────────────
ENVV=()
setenv() { ENVV+=("$1"); }   # o último valor de uma variável vence no `env`
mk_case() {  # $1=nome → cria C=$T/<nome> com stubs "tudo ok" e o vetor ENVV
  SKIP=0
  if [ -n "$ONLY" ] && ! printf '%s' "$1" | grep -Eq "$ONLY"; then
    SKIP=1; C="$T/skip"; mkdir -p "$C"; : > "$C/notify.log"; : > "$C/gc.log"; : > "$C/reboot.calls"; ENVV=(x=1); return 0
  fi
  C="$T/$1"; rm -rf "$C"; mkdir -p "$C/bin" "$C/city/.gc/logs" "$C/rodadas"
  : > "$C/notify.log"; : > "$C/gc.log"; : > "$C/reboot.calls"
  printf 'FileVault is Off.\n' > "$C/fdesetup.out"; echo 0 > "$C/fdesetup.rc"
  printf 'athos\n' > "$C/autologin.out"; echo 0 > "$C/autologin.rc"
  echo 0 > "$C/launchctl.rc"; echo 1 > "$C/pgrep.rc"; : > "$C/pgrep.out"
  echo 0 > "$C/sender.rc"; echo "central_sender_restart_safe: fila sem envio em voo — pode reiniciar" > "$C/sender.out"
  echo 0 > "$C/reboot.rc"; echo 5000000 > "$C/df.kb"
  cat > "$C/bin/notify" <<EOF
#!/bin/bash
echo "\$*" >> "$C/notify.log"
[ -f "$C/notify.hook" ] && bash "$C/notify.hook" "\$*"
exit 0
EOF
  cat > "$C/bin/gc" <<EOF
#!/bin/bash
echo "\$*" >> "$C/gc.log"
exit 0
EOF
  cat > "$C/bin/fdesetup" <<EOF
#!/bin/bash
cat "$C/fdesetup.out"; exit \$(cat "$C/fdesetup.rc")
EOF
  cat > "$C/bin/defaults" <<EOF
#!/bin/bash
cat "$C/autologin.out"; exit \$(cat "$C/autologin.rc")
EOF
  cat > "$C/bin/launchctl" <<EOF
#!/bin/bash
echo "gui/501/x = { state = not running }"; exit \$(cat "$C/launchctl.rc")
EOF
  cat > "$C/bin/pgrep" <<EOF
#!/bin/bash
cat "$C/pgrep.out"; exit \$(cat "$C/pgrep.rc")
EOF
  cat > "$C/bin/sysctl" <<EOF
#!/bin/bash
echo "total = 6144.00M  used = 4096.00M  free = 2048.00M  (encrypted)"
EOF
  cat > "$C/bin/df" <<EOF
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk2s5 239362496 202389956 \$(cat "$C/df.kb") 98% 1 1 1% /System/Volumes/Data"
EOF
  cat > "$C/sender_stub.py" <<EOF
import sys
sys.stdout.write(open("$C/sender.out").read())
sys.exit(int(open("$C/sender.rc").read()))
EOF
  cat > "$C/bin/reboot-stub" <<EOF
#!/bin/bash
echo "called" >> "$C/reboot.calls"
cp "$C/state" "$C/state.at-reboot" 2>/dev/null
cp "$C/notify.log" "$C/notify.at-reboot" 2>/dev/null
env | grep -E '^(LANG|LC_ALL)=' > "$C/reboot.env"
# o desligamento de verdade TERMina o D4: o stub faz o mesmo quando o cenário pede "o mini cai"
if [ -f "$C/reboot.dies" ]; then kill -TERM "\$(cat "$C/state.lock.d/pid")"; sleep 2; fi
exit \$(cat "$C/reboot.rc")
EOF
  cat > "$C/bin/osascript" <<EOF
#!/bin/bash
echo "\$@" > "$C/osascript.args"
env | grep -E '^(LANG|LC_ALL)=' > "$C/osascript.env"
exit 0
EOF
  chmod +x "$C"/bin/*
  cp "$T/pix.empty.db" "$C/pix.db"; cp "$T/vb.empty.db" "$C/vb.db"
  ENVV=(
    "DR_CITY=$C/city" "DR4_STATE=$C/state" "DR4_LOG=$C/log" "DR_OFF_FILE=$C/off"
    "DR_NOTIFY_BIN=$C/bin/notify" "DR_GC_BIN=$C/bin/gc"
    "DR4_NOW=$NOW" "DR4_BOOT_EPOCH=$BOOT" "DR4_FREE_MB_OVERRIDE=2000" "DR4_CONSOLE_USER=athos"
    "DR4_FDESETUP_BIN=$C/bin/fdesetup" "DR4_DEFAULTS_BIN=$C/bin/defaults" "DR4_LAUNCHCTL_BIN=$C/bin/launchctl"
    "DR4_PGREP_BIN=$C/bin/pgrep" "DR4_SYSCTL_BIN=$C/bin/sysctl" "DR4_DF_BIN=$C/bin/df" "DR4_OSASCRIPT_BIN=$C/bin/osascript"
    "DR4_SENDER_SAFE_PY=$C/sender_stub.py" "DR4_NIGHTLY=$NIGHTLY_REAL" "DR4_CALLS_PY=$CALLS"
    "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db" "VOICEBOT_COST_DB=$C/vb.db"
    "SCRAPER_RODADA_DIR=$C/rodadas" "SCRAPER_BOOT_EPOCH=$REALBOOT"
    "DR4_REBOOT_CMD=$C/bin/reboot-stub" "DR4_NO_REAL_REBOOT=1"
    "DR4_GRACE_S=0" "DR4_WAIT_S=1" "DR4_REBOOT_TIMEOUT_S=15" "DR4_GUARD_TIMEOUT_S=30" "DR4_NOTIFY_TIMEOUT_S=10" "DR4_MAIL_TIMEOUT_S=10"
  )
}
run_sut() {  # $1=modo (--run|--dry-run|...) → RC, OUT, NL (linhas no stdout)
  if [ "$SKIP" = 1 ]; then RC=0; OUT=""; NL=1; return 0; fi
  env "${ENVV[@]}" bash "$SUT" "$@" > "$C/stdout.last" 2> "$C/stderr.last"; RC=$?
  OUT=$(cat "$C/stdout.last"); NL=$(wc -l < "$C/stdout.last" | tr -d ' ')
}
n_reboot() { wc -l < "$C/reboot.calls" | tr -d ' '; }
n_notify() { wc -l < "$C/notify.log" | tr -d ' '; }
n_mail()   { grep -c 'mail send' "$C/gc.log"; }
state_has() { [ -f "$C/state" ] && grep -q "$1" "$C/state"; }
contains() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
one_line() { [ "$NL" = 1 ]; }
no_reboot() { [ "$(n_reboot)" = 0 ]; }

# expect <descrição> <rc esperado> [trecho esperado no stdout]: roda --run (sem argumento) e confere rc + 1 linha + "nenhum reboot"
expect_no_reboot() {  # $1=desc $2=rc [$3=trecho]
  check "$1: rc=$2 (veio $RC: $OUT)" [ "$RC" = "$2" ]
  check "$1: uma linha no stdout (veio $NL)" one_line
  check "$1: NÃO pediu reinício" no_reboot
  [ -z "${3:-}" ] || check "$1: stdout cita '$3' (veio: $OUT)" contains "$3"
}

# ═══ 0. contrato de uso ════════════════════════════════════════════════════════════════════════════════════════════════════════
section "uso"
mk_case uso
run_sut;                        check "sem argumento: rc 2" [ "$RC" = 2 ]
run_sut --bogus;                check "argumento desconhecido: rc 2" [ "$RC" = 2 ]
run_sut --run --dry-run;        check "dois modos: rc 2" [ "$RC" = 2 ]
check "uso: nada foi reiniciado" no_reboot

# ═══ 1. dry-run feliz ══════════════════════════════════════════════════════════════════════════════════════════════════════════
section "dry-run feliz (usa o código REAL do nightly-reboot.sh)"
mk_case dry
run_sut --dry-run
check "dry-run: rc 0 (veio $RC: $OUT)" [ "$RC" = 0 ]
check "dry-run: uma linha" one_line
check "dry-run: diz que reiniciaria" contains "reiniciaria agora"
check "dry-run: as 4 guardas leram ok" contains "calls=ok · sender=ok · dolt=ok · scraper=ok"
check "dry-run: NÃO reiniciou" no_reboot
check "dry-run: não escreveu estado" [ ! -e "$C/state" ]
check "dry-run: não avisou" [ "$(n_notify)" = 0 ]
check "dry-run: não mandou mail" [ "$(n_mail)" = 0 ]
check "dry-run: não deixou trava" [ ! -e "$C/state.lock.d" ]

# ═══ 2. reinício de verdade (shutdown simulado) ════════════════════════════════════════════════════════════════════════════════
section "run feliz: o mini 'cai' (o stub mata o D4 como o desligamento)"
mk_case run_ok; touch "$C/reboot.dies"
run_sut --run
check "run: o D4 morreu por TERM (rc 143; veio $RC)" [ "$RC" = 143 ]
check "run: pediu o reinício UMA vez" [ "$(n_reboot)" = 1 ]
check "run: a marca do reinício JÁ estava no disco quando o pedido saiu" grep -q "reboots=$NOW" "$C/state.at-reboot"
check "run: o aviso (-p 5, 'reiniciando') saiu ANTES do pedido" grep -q "reiniciando o mini" "$C/notify.at-reboot"
check "run: o aviso foi push (-p 5)" grep -q -- "-p 5" "$C/notify.at-reboot"
check "run: o aviso diz como abortar" grep -q "touch $C/off" "$C/notify.at-reboot"
check "run: a marca ficou no estado" state_has "reboots=$NOW"
check "run: LANG UTF-8 foi passado ao comando de reinício" grep -q "LANG=en_US.UTF-8" "$C/reboot.env"
check "run: a trava foi solta no TERM" [ ! -e "$C/state.lock.d" ]
check "run: registro do reinício foi gravado" [ -n "$(ls "$C"/city/.gc/logs/disk-recovery-d4-reboot-*.txt 2>/dev/null)" ]
check "run: sem linha no stdout (o mini estava caindo)" [ "$NL" = 0 ]

section "run: o comando de VERDADE é osascript→loginwindow aevtrrst, e só sem DR4_REBOOT_CMD"
mk_case osa; setenv "DR4_REBOOT_CMD="; setenv "DR4_NO_REAL_REBOOT=0"; setenv "DR4_WAIT_S=1"
run_sut --run
chk "osascript: foi chamado com o evento de reinício (veio: $(cat "$C/osascript.args" 2>/dev/null))" 'grep -q "loginwindow" "$C/osascript.args" && grep -q "aevtrrst" "$C/osascript.args"'
check "osascript: LANG UTF-8 explícito" grep -q "LANG=en_US.UTF-8" "$C/osascript.env"
check "osascript aceito mas o mini não caiu: rc 20" [ "$RC" = 20 ]
mk_case norl; setenv "DR4_REBOOT_CMD="; setenv "DR4_NO_REAL_REBOOT=1"
run_sut --run
check "NO_REAL_REBOOT sem stub: rc 20 (veio $RC)" [ "$RC" = 20 ]
check "NO_REAL_REBOOT sem stub: o osascript NÃO foi chamado" [ ! -e "$C/osascript.args" ]
chk "NO_REAL_REBOOT sem stub: a marca foi desfeita" '! state_has "reboots=$NOW"'

# ═══ 3. o pedido falha / não derruba o mini ════════════════════════════════════════════════════════════════════════════════════
section "o pedido de reinício falha"
mk_case rb_fail; echo 1 > "$C/reboot.rc"
run_sut --run
check "pedido com erro: rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
check "pedido com erro: uma linha" one_line
chk "pedido com erro: desfez a marca do reinício" '! state_has "reboots=$NOW"'
check "pedido com erro: guardou a tentativa" state_has "attempt_ts=$NOW"
check "pedido com erro: avisou que FALHOU" grep -q "FALHOU" "$C/notify.log"
setenv "DR4_NOW=$((NOW + 300))"
run_sut --run
check "5 min depois: rc 10 (espera entre tentativas; veio $RC: $OUT)" [ "$RC" = 10 ]
check "5 min depois: não pediu de novo" [ "$(n_reboot)" = 1 ]
setenv "DR4_NOW=$((NOW + 1900))"
run_sut --run
check "31 min depois: tenta de novo (o stub falha de novo, rc 20)" [ "$RC" = 20 ]
check "31 min depois: pediu de novo" [ "$(n_reboot)" = 2 ]

section "o pedido é aceito mas o mini continua no ar"
mk_case rb_up   # reboot.rc 0 e o stub não mata ninguém
run_sut --run
check "mini vivo depois do pedido: rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
check "mini vivo depois do pedido: uma linha" one_line
check "mini vivo depois do pedido: diz que NÃO reiniciou" contains "NÃO reiniciou"
chk "mini vivo depois do pedido: desfez a marca" '! state_has "reboots=$NOW"'
check "mini vivo depois do pedido: avisou" grep -q "NÃO caiu" "$C/notify.log"

# ═══ 4. disco ══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "disco"
mk_case disk_ok; setenv "DR4_FREE_MB_OVERRIDE=3500"
run_sut --run;  expect_no_reboot "disco recuperou" 10 "recuperou"
check "disco recuperou: sem aviso" [ "$(n_notify)" = 0 ]
mk_case disk_edge; setenv "DR4_FREE_MB_OVERRIDE=3072"
run_sut --run;  expect_no_reboot "disco == limiar (>= recupera)" 10 "recuperou"
mk_case disk_bad; setenv "DR4_FREE_MB_OVERRIDE=abc"
run_sut --run;  expect_no_reboot "disco ilegível" 30 "não consegui ler o disco"
mk_case disk_df; setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; touch "$C/reboot.dies"
run_sut --run;  check "df real do stub: lê 2000 MB e reinicia (kill 143; veio $RC)" [ "$RC" = 143 ]
mk_case disk_df_bad; setenv "DR4_FREE_MB_OVERRIDE="; echo "x" > "$C/df.kb"
run_sut --run;  expect_no_reboot "df devolve lixo" 30 "não consegui ler o disco"

# ═══ 5. interruptor ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "interruptor"
mk_case off; touch "$C/off"
run_sut --run;      expect_no_reboot "interruptor (run)" 10 "interruptor"
run_sut --dry-run;  check "interruptor (dry-run): rc 10" [ "$RC" = 10 ]

# ═══ 6. cooldown, teto diário, uptime, espera ═════════════════════════════════════════════════════════════════════════════════
section "cooldown / teto / uptime"
mk_case cool; printf 'v=1\nreboots=%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 3600)) > "$C/state"
run_sut --run;  expect_no_reboot "cooldown (1 h atrás)" 10 "cooldown"
check "cooldown: escalou por notify -p 5" grep -q -- "-p 5" "$C/notify.log"
check "cooldown: escalou por mail ao Mayor" [ "$(n_mail)" = 1 ]
check "cooldown: gravou esc_for" state_has "esc_for=$((NOW - 3600))"
run_sut --run;  expect_no_reboot "cooldown (2ª rodada)" 10 "cooldown"
check "cooldown: NÃO escala duas vezes pelo mesmo reinício (mail=$(n_mail))" [ "$(n_mail)" = 1 ]
mk_case cool_dry; printf 'v=1\nreboots=%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 3600)) > "$C/state"
run_sut --dry-run; chk "cooldown em dry-run: rc 10, sem aviso e sem mail" '[ "$RC" = 10 ] && [ "$(n_notify)" = 0 ] && [ "$(n_mail)" = 0 ]'
mk_case cool_edge; printf 'v=1\nreboots=%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 21600)) > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "cooldown: com exatamente 6 h já pode (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case cap; printf 'v=1\nreboots=%s,%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 50000)) $((NOW - 30000)) > "$C/state"
run_sut --run;  expect_no_reboot "teto de 2 por 24 h" 10 "teto diário"
check "teto: escalou" [ "$(n_mail)" = 1 ]
mk_case cap_one; printf 'v=1\nreboots=%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 30000)) > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "1 reinício em 24 h (>6 h atrás) ainda pode (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case cap_old; printf 'v=1\nreboots=%s,%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 200000)) $((NOW - 150000)) > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "2 reinícios com mais de 24 h podem de novo (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case uptime; setenv "DR4_BOOT_EPOCH=$((NOW - 3000))"
run_sut --run;  expect_no_reboot "mini no ar há 50 min" 10 "no ar há"
mk_case uptime_edge; setenv "DR4_BOOT_EPOCH=$((NOW - 7200))"; touch "$C/reboot.dies"
run_sut --run;  check "mini no ar há exatamente 2 h já pode (kill 143)" [ "$RC" = 143 ]
mk_case boot_bad; setenv "DR4_BOOT_EPOCH=abc"; setenv "DR4_SYSCTL_BIN=/usr/bin/false"
run_sut --run;  expect_no_reboot "boottime ilegível" 30 "quando o mini subiu"

# ═══ 7. estado ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
section "estado ilegível ou ausente"
mk_case st_bad1; echo "reboots=abc" > "$C/state"
run_sut --run;  expect_no_reboot "reboots não numérico" 30 "estado do D4"
mk_case st_bad2; printf 'v=2\nreboots=\n' > "$C/state"
run_sut --run;  expect_no_reboot "versão de estado desconhecida" 30 "estado do D4"
mk_case st_bad3; mkdir "$C/state"
run_sut --run;  expect_no_reboot "estado é um diretório" 30 "estado do D4"
mk_case st_bad4; printf 'v=1\nreboots=1,,2\n' > "$C/state"
run_sut --run;  expect_no_reboot "lista de marcas com elemento vazio" 30 "estado do D4"
mk_case st_bad5; printf 'v=1\ndefer_until=99999999999999999999\n' > "$C/state"
run_sut --run;  expect_no_reboot "número gigante (estouraria a aritmética)" 30 "estado do D4"
mk_case st_new; touch "$C/reboot.dies"
run_sut --run;  check "estado AUSENTE = primeira vez: reinicia (kill 143)" [ "$RC" = 143 ]
mk_case st_unk; printf 'v=1\nfuturo=1\nreboots=\n' > "$C/state"; touch "$C/reboot.dies"
run_sut --run;  check "chave desconhecida é ignorada (kill 143)" [ "$RC" = 143 ]
mk_case st_ro; mkdir "$C/ro"; chmod 555 "$C/ro"; setenv "DR4_STATE=$C/ro/state"; setenv "DR4_LOCKD=$C/ro.lock.d"
run_sut --run;  check "não consegue GRAVAR o estado: NÃO reinicia, rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
check "não consegue gravar: o reinício não foi pedido" no_reboot
chmod 755 "$C/ro"

# ═══ 8. pré-checagem ═════════════════════════════════════════════════════════════════════════════════════════════════════════
section "pré-checagem"
mk_case pre_fv; echo "FileVault is On." > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault ligado" 20 "FileVault"
mk_case pre_fv2; echo "FileVault is Off, but encryption is in progress" > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault em cifragem" 20 "FileVault"
mk_case pre_fv3; echo 2 > "$C/fdesetup.rc"
run_sut --run;  expect_no_reboot "fdesetup falha" 30 "pré-checagem ilegível"
mk_case pre_fv4; echo "algo novo" > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "fdesetup com texto que não reconheço" 30 "não reconheço"
mk_case pre_al1; echo 1 > "$C/autologin.rc"; echo "The domain/default pair of (/Library/Preferences/com.apple.loginwindow, autoLoginUser) does not exist" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin não configurado" 20 "autologin"
mk_case pre_al2; echo "outro" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin de outro usuário" 20 "autologin"
mk_case pre_al3; echo 1 > "$C/autologin.rc"; echo "erro estranho" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "defaults falha por outro motivo" 30 "pré-checagem ilegível"
mk_case pre_al4; : > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autoLoginUser vazio" 30 "vazio"
mk_case pre_lc1; echo 113 > "$C/launchctl.rc"
run_sut --run;  expect_no_reboot "postcheck não carregado" 20 "postcheck"
mk_case pre_lc2; echo 5 > "$C/launchctl.rc"
run_sut --run;  expect_no_reboot "launchctl falha" 30 "pré-checagem ilegível"
mk_case pre_cu; setenv "DR4_CONSOLE_USER="; setenv "DR4_STAT_BIN=/usr/bin/false"
run_sut --run;  expect_no_reboot "usuário do console ilegível" 30 "console"
mk_case pre_osa; setenv "DR4_REBOOT_CMD="; setenv "DR4_NO_REAL_REBOOT=0"; setenv "DR4_OSASCRIPT_BIN=$C/nao-existe"
run_sut --run;  check "sem osascript e sem stub: rc 20 (veio $RC: $OUT)" [ "$RC" = 20 ]
mk_case pre_dry; echo "FileVault is On." > "$C/fdesetup.out"
run_sut --dry-run; check "pré-checagem também vale no dry-run: rc 20" [ "$RC" = 20 ]

# ═══ 9. guardas: bloqueio ═══════════════════════════════════════════════════════════════════════════════════════════════════════
section "guardas bloqueiam (adia 10 min e avisa)"
block_case() {  # $1=nome $2=trecho esperado  (a preparação do bloqueio é feita pelo chamador antes)
  run_sut --run
  expect_no_reboot "guarda $1 bloqueia" 10 "$2"
  chk "guarda $1: avisou uma vez (push)" '[ "$(n_notify)" = 1 ] && grep -q -- "-p 5" "$C/notify.log"'
  check "guarda $1: grava a espera de 10 min" state_has "defer_until=$((NOW + 600))"
  check "guarda $1: o estado NÃO ganhou marca de reinício" state_has "reboots=$"
}
mk_case g_pix;  rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "dialing@3"
block_case "pix (dialing recente)" "calls"
mk_case g_pixb; rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "bridged@30"
block_case "pix (bridged)" "calls"
mk_case g_vb;   rm -f "$C/vb.db"; mkfix vb "$C/vb.db" "live@2"
block_case "voicebot (live)" "calls"
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
run_sut --run;  chk "hold +1min: rc 10 'adiado até' (veio: $OUT)" '[ "$RC" = 10 ] && contains "adiado até"'
check "hold +1min: não avaliou de novo nem avisou (notify=$(n_notify))" [ "$(n_notify)" = 1 ]
setenv "DR4_NOW=$((NOW + 700))"
run_sut --run;  chk "hold +11min: reavalia, segue bloqueado (rc 10, guarda)" '[ "$RC" = 10 ] && contains "guarda(s) bloqueando"'
check "hold +11min: aviso SUPRIMIDO (< 60 min; notify=$(n_notify))" [ "$(n_notify)" = 1 ]
setenv "DR4_NOW=$((NOW + 3700))"
run_sut --run;  chk "hold +62min: bloqueado de novo e AGORA avisa (notify=$(n_notify))" '[ "$RC" = 10 ] && [ "$(n_notify)" = 2 ]'
echo 0 > "$C/sender.rc"; echo "central_sender_restart_safe: fila sem envio em voo — pode reiniciar" > "$C/sender.out"; touch "$C/reboot.dies"
setenv "DR4_NOW=$((NOW + 7400))"
run_sut --run;  check "guarda liberou: reinicia (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case hold_dry; printf 'v=1\nreboots=\nattempt_ts=0\ndefer_until=%s\ndefer_notify_ts=0\nesc_for=0\n' $((NOW + 500)) > "$C/state"
run_sut --dry-run; chk "dry-run não obedece a espera, só informa (rc 0 + nota; veio $RC: $OUT)" '[ "$RC" = 0 ] && contains "adiado até"'

section "uma guarda bloqueia e outra não dá pra ler: bloqueio vence (rc 10)"
mk_case g_mix; echo 1 > "$C/sender.rc"; echo "central_sender_restart_safe: 1 envio(s) em voo" > "$C/sender.out"; echo 2 > "$C/pgrep.rc"
run_sut --run;  expect_no_reboot "bloqueio + ilegível" 10 "sem leitura: dolt"

# ═══ 10. guardas: não consegui ler ══════════════════════════════════════════════════════════════════════════════════════════════
section "guardas ilegíveis nunca reiniciam (rc 30)"
unk_case() {  # $1=nome $2=trecho  (preparo feito antes)
  run_sut --run
  expect_no_reboot "guarda ilegível: $1" 30 "$2"
  check "guarda ilegível $1: avisou (o D4 cego é problema)" [ "$(n_notify)" = 1 ]
}
mk_case u_pix1; rm -f "$C/pix.db"
unk_case "pix: banco ausente" "banco ausente"
mk_case u_pix2; echo "isto não é um banco" > "$C/pix.db"
unk_case "pix: arquivo corrompido" "erro lendo"
mk_case u_pix3; rm -f "$C/pix.db"; mkfix vb-notable "$C/pix.db"
unk_case "pix: tabela ausente" "tabela pix_call_log ausente"
mk_case u_vb1;  rm -f "$C/vb.db"
unk_case "voicebot: banco ausente" "voicebot: banco ausente"
mk_case u_vb2;  rm -f "$C/vb.db"; mkfix vb-notable "$C/vb.db"
unk_case "voicebot: tabela ausente" "tabela voicebot_call_log ausente"
mk_case u_calls1; setenv "DR4_CALLS_PY=$C/nao-existe.py"
unk_case "helper de ligações ausente" "não legível"
mk_case u_calls2; echo 'import sys; sys.exit(7)' > "$C/calls_crash.py"; setenv "DR4_CALLS_PY=$C/calls_crash.py"
unk_case "helper de ligações com rc estranho" "rc=7"
mk_case u_snd1; echo 2 > "$C/sender.rc"; echo "central_sender_restart_safe: NAO SEI se ha envio em voo" > "$C/sender.out"
unk_case "envio: NÃO SEI (rc 2)" "sender"
mk_case u_snd2; echo 1 > "$C/sender.rc"; echo "Traceback (most recent call last): ValueError" > "$C/sender.out"
unk_case "envio: rc 1 de TRACEBACK não é 'em voo'" "sem a mensagem do script"
mk_case u_snd3; setenv "DR4_SENDER_SAFE_PY=$C/nao-existe.py"
unk_case "envio: script ausente" "não legível"
mk_case u_dolt; echo 2 > "$C/pgrep.rc"; echo "pgrep: erro" > "$C/pgrep.out"
unk_case "Dolt: pgrep falha" "pgrep falhou"
mk_case u_scr1; echo "{isso nao e json" > "$C/rodadas/r1.json"
unk_case "scraper: marker ilegível" "scraper"
mk_case u_scr2; setenv "DR4_NIGHTLY=$C/nao-existe.sh"
unk_case "noturno ausente (scraper e Dolt viram 'não sei')" "não legível"
mk_case u_scr3; sed 's/SCRAPER-DAILY-GUARD-START/SCRAPER-DAILY-GUARD-STARTX/' "$NIGHTLY_REAL" > "$C/nightly-drift.sh"; setenv "DR4_NIGHTLY=$C/nightly-drift.sh"
unk_case "sentinela do scraper sumiu (drift)" "sentinela SCRAPER-DAILY-GUARD"
mk_case u_scr4; { cat "$NIGHTLY_REAL"; grep -E 'nightly-reboot.selftest.sh:SCRAPER-DAILY-GUARD-(START|END)' "$NIGHTLY_REAL"; } > "$C/nightly-dup.sh"; setenv "DR4_NIGHTLY=$C/nightly-dup.sh"
unk_case "sentinela do scraper DUPLICADA" "sentinela SCRAPER-DAILY-GUARD"
mk_case u_scr5; sed 's/DOLT-MAINT-PATTERN-END/DOLT-MAINT-PATTERN-ENDX/' "$NIGHTLY_REAL" > "$C/nightly-drift2.sh"; setenv "DR4_NIGHTLY=$C/nightly-drift2.sh"
unk_case "sentinela do Dolt sumiu (drift)" "sentinela DOLT-MAINT-PATTERN"

section "órfãs e estados terminais não seguram; sem data segura"
mk_case o_old;  rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "dialing@360" "bridged@500"
run_sut --dry-run; check "órfãs antigas (> 4 h) NÃO seguram: dry-run reiniciaria (veio $OUT)" [ "$RC" = 0 ]
oo=$(env "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db" "VOICEBOT_COST_DB=$C/vb.db" /usr/bin/python3 -I "$CALLS" 2>&1)
chk "órfãs antigas: o helper as CONTA no detalhe (não somem em silêncio; veio: $oo)" 'case "$oo" in *"2 órfã(s) ignorada(s)"*) true ;; *) false ;; esac'
mk_case o_term; rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "answered_talked@2" "no_answer@1" "voicemail@1"
run_sut --dry-run; check "estados terminais recentes NÃO seguram (veio $OUT)" [ "$RC" = 0 ]
mk_case o_null; rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "dialing@null"
run_sut --dry-run; check "dialing SEM data conta como em curso (rc 10; veio $OUT)" [ "$RC" = 10 ]
mk_case o_vbold; rm -f "$C/vb.db"; mkfix vb "$C/vb.db" "live@600"
run_sut --dry-run; check "voicebot 'live' órfão antigo não segura (veio $OUT)" [ "$RC" = 0 ]

# ═══ 11. releitura depois da carência ═════════════════════════════════════════════════════════════════════════════════════════
section "releitura depois do aviso: o veredito de minutos atrás não vale"
mk_case re_snd; echo "echo 1 > '$C/sender.rc'; echo 'central_sender_restart_safe: 1 envio(s) em voo' > '$C/sender.out'" > "$C/notify.hook"
run_sut --run
check "envio começou durante o aviso: rc 10 (veio $RC: $OUT)" [ "$RC" = 10 ]
check "envio começou durante o aviso: NÃO pediu reinício" no_reboot
chk "envio começou durante o aviso: nenhuma marca de reinício gravada" '[ ! -e "$C/state" ] || ! grep -q "reboots=$NOW" "$C/state"'
check "envio começou durante o aviso: grava a espera" state_has "defer_until=$((NOW + 600))"
check "envio começou durante o aviso: diz 'cancelado' no aviso" grep -q "cancelado" "$C/notify.log"
mk_case re_off; echo "touch '$C/off'" > "$C/notify.hook"; setenv "DR4_GRACE_S=3"
run_sut --run
chk "interruptor ligado durante a carência: rc 10, não reiniciou (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot'
mk_case re_disk; setenv "DR4_FREE_MB_OVERRIDE="; echo 2048000 > "$C/df.kb"; echo "echo 4096000 > '$C/df.kb'" > "$C/notify.hook"
run_sut --run
chk "disco recuperou durante a carência: rc 10, não reiniciou (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot'
mk_case re_unk; echo "echo 2 > '$C/sender.rc'; echo 'nao sei' > '$C/sender.out'" > "$C/notify.hook"
run_sut --run
chk "guarda ficou ilegível durante a carência: rc 30, não reiniciou (veio $RC: $OUT)" '[ "$RC" = 30 ] && no_reboot'
mk_case re_pos; touch "$C/reboot.dies"
run_sut --run
check "controle positivo: sem mudança durante a carência, reinicia (kill 143)" [ "$RC" = 143 ]

# ═══ 12. trava de instância única ═════════════════════════════════════════════════════════════════════════════════════════════
section "instância única"
mk_case lock_live; mkdir "$C/state.lock.d"; sleep 30 & LP=$!; echo "$LP" > "$C/state.lock.d/pid"
run_sut --run;  expect_no_reboot "trava com pid vivo" 10 "outra instância"
check "trava viva: a trava de outro NÃO foi tomada" [ -e "$C/state.lock.d/pid" ]
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
mk_case lock_dead; mkdir "$C/state.lock.d"; echo 99999 > "$C/state.lock.d/pid"; touch "$C/reboot.dies"
run_sut --run;  check "trava com pid MORTO é tomada e o D4 segue (kill 143; veio $RC: $OUT)" [ "$RC" = 143 ]
mk_case lock_nopid; mkdir "$C/state.lock.d"; touch -t 202001010000 "$C/state.lock.d"; touch "$C/reboot.dies"
run_sut --run;  check "trava sem pid e velha é tomada (kill 143)" [ "$RC" = 143 ]
mk_case lock_new; mkdir "$C/state.lock.d"
run_sut --run;  expect_no_reboot "trava sem pid e RECENTE (outro acabou de criar)" 10 "outra instância"
mk_case lock_dry; mkdir "$C/state.lock.d"; echo $$ > "$C/state.lock.d/pid"
run_sut --dry-run; check "dry-run não toma nem respeita a trava (rc 0)" [ "$RC" = 0 ]

# ═══ 13. números ruins no ambiente ══════════════════════════════════════════════════════════════════════════════════════════════
section "limite que não é número cai no padrão e é dito no log"
mk_case num; setenv "DR4_MB=abc"; setenv "DR4_FREE_MB_OVERRIDE=3500"
run_sut --dry-run
check "DR4_MB=abc: usou 3072 (3500 recupera; veio $OUT)" [ "$RC" = 10 ]
check "DR4_MB=abc: o log diz que caiu no padrão" grep -q "DR4_MB='abc'->3072" "$C/log"
mk_case num2; setenv "DR4_COOLDOWN_S=1x"; printf 'v=1\nreboots=%s\nattempt_ts=0\ndefer_until=0\ndefer_notify_ts=0\nesc_for=0\n' $((NOW - 3600)) > "$C/state"
run_sut --run;  chk "cooldown lixo vira 21600 (continua em cooldown; veio $RC: $OUT)" '[ "$RC" = 10 ] && contains "cooldown"'

# ═══ 14. o leitor de ligações (calls-in-flight.py) ═══════════════════════════════════════════════════════════════════════════
section "calls-in-flight.py direto"
mk_case cf
sha_before=$(shasum "$C/pix.db" "$C/vb.db" | awk '{print $1}' | tr '\n' ' ')
no_shm_before=0; [ ! -e "$C/pix.db-shm" ] && [ ! -e "$C/pix.db-wal" ] && no_shm_before=1
out=$(env "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db" "VOICEBOT_COST_DB=$C/vb.db" /usr/bin/python3 -I "$CALLS" 2>&1); rc=$?
check "helper: ok com os dois bancos vazios (rc 0; veio $rc: $out)" [ "$rc" = 0 ]
chk "helper: banco WAL SEM -shm/-wal abre (a falha medida ao vivo: mode=ro dava 34 erros em 40)" '[ "$no_shm_before" = 1 ] && [ "$rc" = 0 ]'
sha_after=$(shasum "$C/pix.db" "$C/vb.db" | awk '{print $1}' | tr '\n' ' ')
check "helper: não alterou o arquivo principal dos bancos" [ "$sha_before" = "$sha_after" ]
chk "helper: o -wal que sobra está VAZIO (nenhuma escrita de dado)" '[ ! -s "$C/pix.db-wal" ] && [ ! -s "$C/vb.db-wal" ]'
out=$(env "PIX_CALL_QUEUE_DEMAND_DB=$C/nao-existe.db" "VOICEBOT_COST_DB=$C/vb.db" /usr/bin/python3 -I "$CALLS" 2>&1); rc=$?
check "helper: banco ausente = unknown (rc 2)" [ "$rc" = 2 ]
check "helper: banco ausente NÃO é criado" [ ! -e "$C/nao-existe.db" ]
rm -f "$C/pix.db"; mkfix pix "$C/pix.db" "dialing@1"
rm -f "$C/vb.db"; mkfix vb "$C/vb.db" "live@1"
out=$(env "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db" "VOICEBOT_COST_DB=$C/vb.db" /usr/bin/python3 -I "$CALLS" 2>&1); rc=$?
check "helper: dois bancos com ligação = block (rc 1; veio $rc: $out)" [ "$rc" = 1 ]
out=$(env "PIX_CALL_QUEUE_DEMAND_DB=$C/pix.db" "VOICEBOT_COST_DB=$C/nao-existe.db" /usr/bin/python3 -I "$CALLS" 2>&1); rc=$?
check "helper: block (pix) + unknown (voicebot) = block, o bloqueio vence (rc 1)" [ "$rc" = 1 ]
out=$(/usr/bin/python3 -I "$CALLS" --max-age-min 0 2>&1); rc=$?
check "helper: --max-age-min 0 é erro de uso (rc 64)" [ "$rc" = 64 ]
out=$(/usr/bin/python3 -I "$CALLS" --bogus 2>&1); rc=$?
check "helper: argumento desconhecido é erro de uso (rc 64)" [ "$rc" = 64 ]
# o bloqueio não depende de uma escrita: a conexão tem query_only (um INSERT tem de falhar)
out=$(/usr/bin/python3 -I -c "
import sqlite3
c = sqlite3.connect('file:$C/pix.db?mode=rw', uri=True); c.execute('PRAGMA query_only=ON')
try:
    c.execute(\"INSERT INTO pix_call_log (call_id, state) VALUES ('x','dialing')\"); print('escreveu')
except sqlite3.Error as e:
    print('recusou')
" 2>&1)
check "query_only recusa escrita (a premissa do helper; veio: $out)" [ "$out" = recusou ]

echo
echo "disk-recovery-d4-guarded-reboot.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
