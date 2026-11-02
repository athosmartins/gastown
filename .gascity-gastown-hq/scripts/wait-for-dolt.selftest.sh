#!/usr/bin/env bash
# wait-for-dolt.selftest.sh — hermético: ps/lsof/pgrep/sysctl de mentira num PATH de mktemp, um "dolt" que é um `sleep` de verdade (o kill -0 da lib é real; só a identidade
# e o LISTEN são falsos, como no dolt-pid-lib.selftest.sh). A lib usada é a REAL (dolt-pid-lib.sh), então o wrapper é testado contra a sonda de verdade. Roda o wrapper no
# /bin/bash do macOS (3.2), que é o que o launchd acha no PATH.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: pronto na hora → exec, rc e argumentos preservados, silêncio · Dolt sobe depois → espera e roda · NÃO veio no prazo → rc 75, comando NÃO roda, linha com o prazo ·
#   prazo 0 · sonda indisponível (lib ausente, sem a função, sem lsof) → rc 76 e NÃO roda · sonda que falha ou devolve lixo → nunca "pronto" · só um decoy (pgrep devolve um PID
#   que não é o dolt) → continua esperando · prazo ilegível → padrão 300 + AVISO (observado pelo prazo anunciado) · flag vence a env · uso errado → 64 · janela de boot: fora dela
#   o wrapper é transparente, dentro dela espera, uptime ilegível/lixo → trata como boot · lib achada ao lado do script quando não há WAIT_FOR_DOLT_LIB.
# BORDAS (ga-ow127o6, lastro hq-mutants): inteiro no teto (3600), 6 dígitos com zeros, 7 dígitos · relógio de mentira (date/sysctl): uptime 0, relógio antes do boot, date ou
#   sysctl que SAEM ≠0 imprimindo um valor bom, date com lixo · --timeout/--boot-window com valor mas sem comando · --boot-window 1 · lib que existe mas não carrega (76) · prazo 0 não anuncia espera.
# EQUIVALENTE (ga-ow127o6; 7fb475c066, o `return 0` do ramo "passa de $4" de pick_int virando `return 1`): pick_int só é chamada em `X=$(pick_int ...)`, o script não tem `set -e` e ninguém
#   lê o status da substituição (só o stdout, o padrão), então `return 0` e `return 1` deixam o mesmo estado e o mesmo rc de saída: nenhum caso vê a diferença.
# CONTROLE NEGATIVO: cada guarda é adulterada (sed numa cópia, pela marca `GUARD:` do script) e o caso que a cobre TEM que passar a falhar; mutante que não muda o arquivo também falha.
# VARIÁVEIS: WFD_UNDER_TEST (script a testar) · WFD_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${WFD_UNDER_TEST:-$HERE/wait-for-dolt.sh}"
LIBSRC="$HERE/dolt-pid-lib.sh"
T=$(cd "$(mktemp -d /tmp/wfd.XXXXXX)" && pwd -P)
S="$T/state"; RAN="$S/ran"; mkdir -p "$S" "$T/bin" "$T/bin-nolsof"
BG=""
cleanup() {
  [ -n "$BG" ] && wait "$BG" 2>/dev/null
  for f in pid decoy; do [ -r "$S/$f" ] && kill "$(cat "$S/$f")" 2>/dev/null; done
  find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null
}
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# ---- stubs (a identidade do "dolt" é o PID gravado em $S/pid; o decoy é um sleep vivo que NÃO é dolt)
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
pid=""; for a in "$@"; do case "$a" in [0-9]*) pid="$a" ;; esac; done
if [ -r "$WFD_STATE/pid" ] && [ "$pid" = "$(cat "$WFD_STATE/pid")" ]; then echo dolt; else echo sleep; fi
EOF
cat > "$T/bin/lsof" <<'EOF'
#!/bin/sh
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -r "$WFD_STATE/pid" ] && [ "$pid" = "$(cat "$WFD_STATE/pid")" ]
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
[ -r "$WFD_STATE/decoy" ] && cat "$WFD_STATE/decoy"
[ -r "$WFD_STATE/pid" ] && cat "$WFD_STATE/pid"
exit 0
EOF
cat > "$T/bin/sysctl" <<'EOF'
#!/bin/sh
f="$WFD_STATE/uptime"; [ -r "$f" ] || exit 1
v=$(cat "$f"); case "$v" in garbage) echo "garbage in"; exit 0 ;; esac
echo "{ sec = $(( $(date +%s) - v )), usec = 0 } Mon Jan  1 00:00:00 2026"
EOF
cat > "$T/cmd.sh" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; } > "$WFD_STATE/ran"
exit "${CMD_RC:-0}"
EOF
chmod +x "$T"/bin/* "$T/cmd.sh"
for b in ps pgrep sysctl; do ln -s "$T/bin/$b" "$T/bin-nolsof/$b"; done
for b in date dirname sleep; do ln -s "$(command -v "$b")" "$T/bin-nolsof/$b"; done

# relógio de mentira (ga-ow127o6): `date +%s` e `sysctl -n kern.boottime` com valores FIXOS, para os casos de borda do uptime; qualquer outro `date` é o de verdade
mkdir -p "$T/bin-clock"
cat > "$T/bin-clock/date" <<'EOF'
#!/bin/sh
case "$*" in
  *"+%s"*)
    case "$(cat "$WFD_STATE/clock_mode" 2>/dev/null)" in
      junk) echo abc; exit 0 ;;
      failval) cat "$WFD_STATE/clock_now"; exit 1 ;;
      *) cat "$WFD_STATE/clock_now" ;;
    esac ;;
  *) exec /bin/date "$@" ;;
esac
EOF
cat > "$T/bin-clock/sysctl" <<'EOF'
#!/bin/sh
echo "{ sec = $(cat "$WFD_STATE/clock_boot"), usec = 0 } Mon Jan  1 00:00:00 2026"
[ "$(cat "$WFD_STATE/sysctl_rc" 2>/dev/null)" = fail ] && exit 1
exit 0
EOF
chmod +x "$T/bin-clock/date" "$T/bin-clock/sysctl"
for b in ps lsof pgrep; do ln -s "$T/bin/$b" "$T/bin-clock/$b"; done

dolt_down() { [ -r "$S/pid" ] && kill "$(cat "$S/pid")" 2>/dev/null; rm -f "$S/pid"; }
dolt_up() { dolt_down; sleep 600 >/dev/null 2>&1 & echo $! > "$S/pid"; disown 2>/dev/null; }
up_later() { ( sleep "$1"; dolt_up ) >/dev/null 2>&1 & BG=$!; }
set_uptime() { if [ "$1" = off ]; then rm -f "$S/uptime"; else printf '%s' "$1" > "$S/uptime"; fi; }

rc=0
run_w() {
  rm -f "$RAN" "$T/out" "$T/err"
  local lib="${WAIT_FOR_DOLT_LIB-$LIBSRC}" e=(env)
  if [ "$lib" = UNSET ]; then e+=(-u WAIT_FOR_DOLT_LIB); else e+=(WAIT_FOR_DOLT_LIB="$lib"); fi
  e+=(PATH="${WFD_PATH:-$T/bin:/usr/bin:/bin:/usr/sbin:/sbin}" GC_CITY="$T/city" WFD_STATE="$S")
  "${e[@]}" /bin/bash "$W" "$@" >"$T/out" 2>"$T/err" </dev/null
  rc=$?
  [ -n "$BG" ] && { wait "$BG" 2>/dev/null; BG=""; }
  return 0
}
export WAIT_FOR_DOLT_POLL=0.2
ran() { [ -e "$RAN" ]; }
errhas() { grep -q -- "$1" "$T/err"; }
fresh() { dolt_down; [ -r "$S/decoy" ] && kill "$(cat "$S/decoy")" 2>/dev/null; rm -f "$S/decoy"; set_uptime off; }

# ---- casos (cada um devolve 0 = passou; a suíte e os mutantes usam as mesmas funções)
t_ready_rc_args() { fresh; dolt_up; CMD_RC=7 run_w --timeout 5 -- "$T/cmd.sh" "a b" c; [ "$rc" = 7 ] && [ "$(cat "$RAN" 2>/dev/null)" = "[a b][c]" ] && [ ! -s "$T/err" ]; }
t_wait_then_run() { fresh; up_later 1.2; run_w --timeout 10 -- "$T/cmd.sh"; [ "$rc" = 0 ] && ran && errhas 'aguardando o Dolt' && errhas 'Dolt pronto'; }
t_timeout_inert() { fresh; local s=$SECONDS; run_w --timeout 2 -- "$T/cmd.sh"; local d=$((SECONDS - s)); [ "$rc" = 75 ] && ! ran && errhas 'NÃO ficou pronto' && errhas 'prazo 2s' && [ "$d" -ge 2 ] && [ "$d" -le 6 ]; }
t_timeout_zero() { fresh; run_w --timeout 0 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran; }
t_decoy_not_ready() { fresh; sleep 600 >/dev/null 2>&1 & echo $! > "$S/decoy"; disown 2>/dev/null; run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran; }
t_probe_lib_missing() { fresh; WAIT_FOR_DOLT_LIB="$T/nao-existe.sh" run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 76 ] && ! ran && errhas 'sonda indisponível'; }
t_probe_no_function() { fresh; echo 'x=1' > "$T/lib-nofn.sh"; WAIT_FOR_DOLT_LIB="$T/lib-nofn.sh" run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 76 ] && ! ran; }
t_probe_no_lsof() { fresh; dolt_up; WFD_PATH="$T/bin-nolsof" run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 76 ] && ! ran && errhas "falta 'lsof'"; }
t_probe_fails() { fresh; echo 'dolt_server_pid() { return 3; }' > "$T/lib-fail.sh"; WAIT_FOR_DOLT_LIB="$T/lib-fail.sh" run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran; }
t_probe_garbage() { fresh; echo "dolt_server_pid() { printf 'abc'; return 0; }" > "$T/lib-junk.sh"; WAIT_FOR_DOLT_LIB="$T/lib-junk.sh" run_w --timeout 1 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran; }
t_invalid_timeout() { # prazo ilegível → o prazo ANUNCIADO é 300 (o Dolt sobe 0,6 s depois, então ninguém espera 300 s)
  local v; for v in abc "" -5 99999 1e3; do fresh; up_later 0.6; run_w --timeout "$v" -- "$T/cmd.sh"
    [ "$rc" = 0 ] && ran && errhas 'AVISO' && errhas 'prazo 300s' || return 1; done
  fresh; up_later 0.6; WAIT_FOR_DOLT_TIMEOUT=xyz run_w -- "$T/cmd.sh"; [ "$rc" = 0 ] && errhas 'AVISO: WAIT_FOR_DOLT_TIMEOUT' && errhas 'prazo 300s'; }
t_valid_timeout_quiet() { fresh; dolt_up; WAIT_FOR_DOLT_TIMEOUT=abc run_w --timeout 08 -- "$T/cmd.sh"; [ "$rc" = 0 ] && ran && [ ! -s "$T/err" ]; }   # flag vence a env; "08" não é octal
t_usage() { local r; fresh; dolt_up
  run_w; r=$rc; run_w --timeout 5 --; [ "$r" = 64 ] && [ "$rc" = 64 ] || return 1
  run_w --bogus -- "$T/cmd.sh"; [ "$rc" = 64 ] || return 1
  run_w --timeout; [ "$rc" = 64 ] && ! ran; }
t_boot_passthrough() { fresh; set_uptime 5000; CMD_RC=3 run_w --timeout 1 --boot-window 900 -- "$T/cmd.sh"; [ "$rc" = 3 ] && ran && [ ! -s "$T/err" ]; }
t_boot_within_waits() { fresh; set_uptime 100; run_w --timeout 1 --boot-window 900 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran || return 1
  fresh; set_uptime 100; dolt_up; run_w --timeout 1 --boot-window 900 -- "$T/cmd.sh"; [ "$rc" = 0 ] && ran; }
t_boot_edge() { fresh; set_uptime 900; run_w --timeout 1 --boot-window 900 -- "$T/cmd.sh"; [ "$rc" = 0 ] && ran; }   # uptime == janela já é "fora do boot"
t_boot_unreadable() { local u; for u in off garbage; do fresh; set_uptime "$u"; run_w --timeout 1 --boot-window 900 -- "$T/cmd.sh"
    [ "$rc" = 75 ] && ! ran && errhas 'uptime ilegível' || return 1; done; }
t_boot_window_invalid() { fresh; set_uptime 5000; run_w --timeout 1 --boot-window x -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran && errhas "AVISO: --boot-window"; }   # janela ilegível = 0 = sempre espera
t_lib_beside_script() { fresh; dolt_up; mkdir -p "$T/pair"; cp "$W" "$T/pair/wait-for-dolt.sh"; cp "$LIBSRC" "$T/pair/dolt-pid-lib.sh"
  local save="$W"; W="$T/pair/wait-for-dolt.sh"; WAIT_FOR_DOLT_LIB=UNSET run_w --timeout 2 -- "$T/cmd.sh"; local r=$rc; W="$save"; [ "$r" = 0 ] && ran; }

# ---- bordas (ga-ow127o6): ids dos mutantes do lastro entre parênteses
t_pick_int_edges() {   # (3635f5965f 7bbb4d4855 7bfe6de6dc) o teto vale, 6 dígitos com zeros valem, 7 dígitos já "passam de"
  fresh; up_later 0.4; run_w --timeout 3600 -- "$T/cmd.sh"
  [ "$rc" = 0 ] && ran && errhas 'prazo 3600s' && ! errhas 'AVISO' || return 1
  fresh; up_later 0.4; run_w --timeout 000999 -- "$T/cmd.sh"
  [ "$rc" = 0 ] && ran && errhas 'prazo 999s' && ! errhas 'AVISO' || return 1
  fresh; up_later 0.4; run_w --timeout 0000999 -- "$T/cmd.sh"
  [ "$rc" = 0 ] && ran && errhas 'AVISO' && errhas 'prazo 300s'; }
clock() {   # $1 agora · $2 boot · $3 modo do date (ok|junk|failval) · $4 rc do sysctl (ok|fail)
  printf '%s' "$1" > "$S/clock_now"; printf '%s' "$2" > "$S/clock_boot"; printf '%s' "${3:-ok}" > "$S/clock_mode"; printf '%s' "${4:-ok}" > "$S/sysctl_rc"; }
run_clock() { WFD_PATH="$T/bin-clock:/usr/bin:/bin:/usr/sbin:/sbin" run_w --timeout 2 --boot-window 900 -- "$T/cmd.sh"; }
t_clock_uptime_zero() { fresh; dolt_up; clock 1700000000 1700000000; run_clock   # (9fc62b8b6a) agora == boot é uptime 0, legível, dentro da janela
  [ "$rc" = 0 ] && ran && ! errhas 'uptime ilegível'; }
t_clock_before_boot() { fresh; dolt_up; clock 1700000000 1700000100; run_clock   # (3ebedb39a7 ecb4339113) relógio ANTES do boot não é uptime: trata como boot e avisa
  [ "$rc" = 0 ] && ran && errhas 'uptime ilegível'; }
t_clock_date_fails() { fresh; dolt_up; clock 1700005000 1700000000 failval; run_clock   # (703f6bcd5d 93cac30401) date que SAI ≠0 não vale, mesmo imprimindo um número que passaria da janela
  [ "$rc" = 0 ] && ran && errhas 'uptime ilegível'; }
t_clock_date_junk() { fresh; dolt_up; clock abc 1700000000 junk; run_clock   # (0f2673a407) date com lixo no lugar do epoch
  [ "$rc" = 0 ] && ran && errhas 'uptime ilegível'; }
t_sysctl_fails_with_value() { fresh; dolt_up; clock 1700005000 1700000000 ok fail; run_clock   # (052196032d) sysctl que SAI ≠0 não vale, mesmo imprimindo um boottime bom
  [ "$rc" = 0 ] && ran && errhas 'uptime ilegível'; }
t_usage_messages() { fresh; dolt_up   # (6cd8e541b2 2cfd7b401b 24722d8d73 1f13454702) a flag COM valor e SEM comando é "falta o comando", a flag sem valor é "sem valor"
  run_w --timeout 5; [ "$rc" = 64 ] && errhas 'falta o comando' && ! ran || return 1
  run_w --boot-window 5; [ "$rc" = 64 ] && errhas 'falta o comando' && ! ran || return 1
  run_w --timeout; [ "$rc" = 64 ] && errhas '--timeout sem valor' || return 1
  run_w --boot-window; [ "$rc" = 64 ] && errhas '--boot-window sem valor'; }
t_boot_window_one() { fresh; set_uptime 5000; run_w --timeout 1 --boot-window 1 -- "$T/cmd.sh"; [ "$rc" = 0 ] && ran && [ ! -s "$T/err" ]; }   # (86d0acd77d) janela de 1 s já é janela: fora dela passa direto
t_lib_load_fails() { fresh; dolt_up; echo 'return 1' > "$T/lib-bad.sh"; WAIT_FOR_DOLT_LIB="$T/lib-bad.sh" run_w --timeout 1 -- "$T/cmd.sh"   # (8393335752) lib legível que não carrega: 76, comando NÃO roda
  [ "$rc" = 76 ] && ! ran && errhas 'não consegui carregar'; }
t_timeout_zero_quiet() { fresh; run_w --timeout 0 -- "$T/cmd.sh"; [ "$rc" = 75 ] && ! ran && errhas 'NÃO ficou pronto' && ! errhas 'aguardando o Dolt'; }   # (4f383fec9d) prazo 0 sai antes de anunciar espera

if [ ! -r "$W" ]; then echo "FAIL o script a testar não existe: $W"; exit 1; fi
ok_t() { "$1"; ok $? "$2"; }
ok_t t_ready_rc_args       "Dolt pronto: exec, rc 7 e argumentos com espaço preservados, silencioso"
ok_t t_wait_then_run       "Dolt sobe depois: espera, anuncia e roda"
ok_t t_timeout_inert       "Dolt não veio: rc 75, comando NÃO roda, linha com o prazo, espera ~ o prazo"
ok_t t_timeout_zero        "prazo 0: sonda uma vez e sai com 75 sem esperar"
ok_t t_decoy_not_ready     "só um decoy (PID que não é o dolt): segue esperando e dá 75"
ok_t t_probe_lib_missing   "lib da sonda ausente: rc 76 (distinto de 75) e NÃO roda"
ok_t t_probe_no_function   "lib sem dolt_server_pid: rc 76 e NÃO roda"
ok_t t_probe_no_lsof       "sem lsof no PATH: rc 76 e NÃO roda, mesmo com o Dolt de pé"
ok_t t_probe_fails         "sonda que falha (rc≠0, sem saída): nunca pronto → 75"
ok_t t_probe_garbage       "sonda que devolve lixo que não é PID: nunca pronto → 75"
ok_t t_invalid_timeout     "prazo ilegível (abc, vazio, -5, 99999, 1e3, env): padrão 300 + AVISO"
ok_t t_valid_timeout_quiet "flag vence a env ilegível; '08' vale 8 e não dá AVISO"
ok_t t_usage               "uso errado (sem comando, sem valor, flag desconhecida): rc 64 e nada roda"
ok_t t_boot_passthrough    "fora da janela de boot: transparente (roda sem sondar, rc 3 preservado, sem log)"
ok_t t_boot_within_waits   "dentro da janela: espera (75 sem Dolt) e roda (com Dolt)"
ok_t t_boot_edge           "uptime == janela conta como fora do boot"
ok_t t_boot_unreadable     "uptime ilegível (sysctl falha ou lixo): trata como boot, espera e avisa"
ok_t t_boot_window_invalid "janela ilegível: AVISO e padrão 0 (sempre espera)"
ok_t t_lib_beside_script   "sem WAIT_FOR_DOLT_LIB a lib é a que está ao lado do script"
ok_t t_pick_int_edges      "inteiro: 3600 vale sem AVISO, 000999 (6 dígitos) vale 999, 0000999 (7 dígitos) cai no padrão com AVISO"
ok_t t_clock_uptime_zero   "relógio: agora == boot é uptime 0, legível (sem AVISO), dentro da janela"
ok_t t_clock_before_boot   "relógio antes do boot: uptime ilegível, trata como boot e avisa"
ok_t t_clock_date_fails    "date que sai ≠0 (mesmo imprimindo um número): uptime ilegível, não passa direto"
ok_t t_clock_date_junk     "date com lixo no lugar do epoch: uptime ilegível"
ok_t t_sysctl_fails_with_value "sysctl que sai ≠0 (mesmo imprimindo um boottime bom): uptime ilegível"
ok_t t_usage_messages      "flag com valor e sem comando = 'falta o comando'; flag sem valor = 'sem valor'"
ok_t t_boot_window_one     "janela de 1 s: uptime longo passa direto, silencioso"
ok_t t_lib_load_fails      "lib legível que não carrega: rc 76 e NÃO roda"
ok_t t_timeout_zero_quiet  "prazo 0: 75 sem anunciar espera"
bash32=$(/bin/bash --version | head -1); echo "     (rodou no: $bash32)"

# ---- controle negativo
if [ "${WFD_NO_MUTANTS:-0}" != 1 ]; then
  mkdir -p "$T/mut"
  mutant() { # $1 nome  $2 expressão sed  $3 caso que cobre
    local save="$W" m="$T/mut/wait-for-dolt.sh"
    sed "$2" "$save" > "$m"; chmod +x "$m"
    if cmp -s "$save" "$m"; then ok 1 "mutante $1: o sed NÃO mudou o script (mutante vazio)"; return; fi
    # mutante com erro de sintaxe "morre" por qualquer motivo e não prova a guarda: não saber rodar ≠ ter reprovado
    if ! /bin/bash -n "$m" 2>/dev/null; then ok 1 "mutante $1: o sed produziu bash inválido (morte por sintaxe não prova a guarda)"; return; fi
    W="$m"; "$3" >/dev/null 2>&1; local r=$?; W="$save"
    if [ "$r" != 0 ]; then ok 0 "mutante $1 reprova $3"; else ok 1 "mutante $1 SOBREVIVEU a $3"; fi
  }
  mutant timeout-roda     '/GUARD:timeout-inert/ s/exit 75/exec "$@"/'                          t_timeout_inert
  mutant rc-76-igual-75   '/sonda indisponível/ s/exit 76/exit 75/'                              t_probe_lib_missing
  mutant falha-vira-pronto '/GUARD:probe-fail-not-ready/ s/|| pid=""/|| pid=1/'                  t_probe_fails
  mutant lixo-vira-pronto '/GUARD:garbage-pid/ d'                                                t_probe_garbage
  mutant rc-perdido       '/GUARD:final-exec/ s/exec "\$@"/"$@"; exit 0/'                       t_ready_rc_args
  mutant sem-passthrough  '/GUARD:passthrough/ s/exec "\$@"; fi/:; fi/'                         t_boot_passthrough
  mutant uptime-ilegivel-roda '/GUARD:uptime-unknown-gates/ s/log .*$/exec "$@"/'               t_boot_unreadable
  mutant prazo-ilegivel-cru '/GUARD:pick-int/ s/printf .%s. "\$3"; return 0 ;; esac/printf "%s" "$2"; return 0 ;; esac/' t_invalid_timeout
  mutant sem-aviso        '/GUARD:pick-int/ s/log "AVISO/: "AVISO/'                              t_invalid_timeout
fi
echo "$n casos, $fails falha(s)"
[ "$fails" = 0 ]
