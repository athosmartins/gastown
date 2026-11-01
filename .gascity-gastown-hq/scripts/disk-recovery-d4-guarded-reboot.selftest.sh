#!/bin/bash
# disk-recovery-d4-guarded-reboot.selftest.sh — prova do D4 (ga-1p1i5jr.4) com SHUTDOWN SIMULADO. Nunca reinicia nada de verdade.
#
# ## Contents
#   O que prova · Como não reinicia · Filtro de cenários
#
# O QUE PROVA: o reinício só acontece com TODAS as guardas "ok", e "não consegui ler" (3º estado) NUNCA reinicia (disco, estado, pré-checagem,
#   cada guarda, a extração do código do reinício noturno); o aviso sai ANTES do pedido; a marca do reinício está NO DISCO antes do pedido; as guardas
#   são relidas depois da carência; cooldown de 6 h, teto de 2 por 24 h, mini no ar há < 2 h, espera de 10 min; pedido que falha ou que não derruba
#   o mini desfaz a marca e sai 20; UMA linha no stdout; dry-run não escreve nem avisa. A guarda de ligação é um STUB (o leitor de verdade e o
#   código dele têm selftest próprio: disk-recovery-d4-calls-in-flight.selftest.sh).
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
stub() {  # $1=nome $2=conteúdo do script em $C/bin
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
  echo 0 > "$C/reboot.rc"; echo 5000000 > "$C/df.kb"
  stub notify "echo \"\$*\" >> $C/notify.log; [ -f $C/notify.hook ] && bash $C/notify.hook \"\$*\"; exit 0"
  stub gc "echo \"\$*\" >> $C/gc.log"
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
chk "pedido que estoura o prazo espera como se tivesse pegado (não 'falhou'; veio $RC: $OUT)" '[ "$RC" = 20 ] && contains "continuou no ar" && ! contains "falhou"'

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
chk "mini vivo depois do pedido: diz que NÃO reiniciou, desfez a marca e avisou" 'contains "NÃO reiniciou" && ! state_has "reboots=$NOW" && grep -q "NÃO caiu" "$C/notify.log"'

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
run_sut --dry-run; chk "cooldown em dry-run: rc 10, sem aviso e sem mail" '[ "$RC" = 10 ] && [ "$(n_notify)" = 0 ] && [ "$(n_mail)" = 0 ]'
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

section "pré-checagem"
mk_case pre_fv;  echo "FileVault is On." > "$C/fdesetup.out"
run_sut --run;  expect_no_reboot "FileVault ligado" 20 "FileVault"
mk_case pre_fv3; echo 2 > "$C/fdesetup.rc"
run_sut --run;  expect_no_reboot "fdesetup falha (não sei)" 30 "pré-checagem ilegível"
mk_case pre_al1; echo 1 > "$C/autologin.rc"; echo "The domain/default pair of (x, autoLoginUser) does not exist" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin não configurado" 20 "autologin"
mk_case pre_al2; echo "outro" > "$C/autologin.out"
run_sut --run;  expect_no_reboot "autologin de outro usuário" 20 "autologin"
mk_case pre_lc1; echo 113 > "$C/launchctl.rc"
run_sut --run;  expect_no_reboot "postcheck não carregado" 20 "postcheck"

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

# ═══ releitura depois da carência, trava ═════════════════════════════════════════════════════════════════════════════════════════
section "releitura depois do aviso: o veredito de minutos atrás não vale"
mk_case re_snd; echo "echo 1 > '$C/sender.rc'; echo 'central_sender_restart_safe: 1 envio(s) em voo' > '$C/sender.out'" > "$C/notify.hook"
run_sut --run
chk "envio começou durante o aviso: rc 10, NÃO pediu reinício, nenhuma marca, grava a espera (veio $RC: $OUT)" '[ "$RC" = 10 ] && no_reboot && ! state_has "reboots=$NOW" && state_has "defer_until=$((NOW + 600))"'
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

echo
echo "disk-recovery-d4-guarded-reboot.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
