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
