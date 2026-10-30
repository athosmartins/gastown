#!/usr/bin/env bash
# mbp-host.selftest.sh — hermético: a sonda é um stub (MBP_HOST_PROBE) ou um `nc` falso no PATH; nada toca a rede, o MBP nem o ~/.ssh.
#
# Contents
#   Casos · Controles negativos · O que NÃO prova
#
# CASOS (ga-bmmxka): os dois respondem → Tailscale · só o Tailscale → Tailscale · só a LAN → LAN · nenhum responde → Tailscale ·
#   sonda ausente/inexecutável → Tailscale · a sonda recebe (host sem usuário, 22) · MBP_TS_HOST/MBP_LAN_HOST trocam os nomes ·
#   `nc` pendurado (mDNS): o relógio de parede corta — Tailscale mudo + LAN pendurada, as duas penduradas, Tailscale respondeu + LAN
#   pendurada (não espera por ela) · MBP_HOST_PROBE_S inválido volta a 2 · sem `nc` no PATH → Tailscale · saída = UMA linha não vazia ·
#   incluído (source) não imprime nada e define a função · o mesmo sob /bin/bash (3.2 no macOS).
#   O rc de _mbp_host_up chamado direto (ga-dw1h9h3): host vazio nunca é "respondeu" nem chega à sonda · sem nc o rc não é 0 · os segundos do relógio de
#   parede (1, 3, 10 valem como vieram; ausente, vazio, 0, 00, negativo e lixo voltam a 2), lidos de um `sleep` falso que só registra o argumento.
# CONTROLES NEGATIVOS: mutantes do helper que os casos têm de reprovar: nada respondeu → LAN · o Tailscale nem é perguntado (LAN ganha
#   quando responde) · sem relógio de parede (nc pendurado segura o chamador) · host vazio / sem nc contam como "respondeu" · segundos válidos
#   viram 2 · 1 s vira 2 s. Pulado sem timeout/gtimeout no PATH (o mutante pendura).
# EQUIVALENTE, de propósito sem mutante (ga-dw1h9h3, lastro hq-mutants, id 955b526b3c): tirar o `|| return 1` de `command -v nc >/dev/null 2>&1 || return 1`. Sem nc a linha seguinte (`nc -z …`) falha com 127 e a
#   função devolve 127 em vez de 1; o contrato dela é "0 = respondeu, qualquer outra coisa = sem evidência", então nenhum caso pode (nem deve) distinguir 1 de 127. O que os casos fixam é o outro lado: o rc NÃO ser 0.
# O QUE NÃO PROVA: o nc/DNS/MagicDNS de verdade (o ao vivo é `bash scripts/mbp-host.sh` no mini) nem o consumo pelo mbp-run.sh, pelo
#   dolt-restore-lab-mbp.sh e pelo mbp-proof.py (cada selftest deles fixa o host).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${MBPH_UNDER_TEST:-$HERE/mbp-host.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-host-selftest.XXXXXX") || exit 2
trap 'find "$T" -delete 2>/dev/null' EXIT
TS="athos@athoss-macbook-pro"; LAN="athos@athoss-macbook-pro.local"
TMO=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
n=0; fails=0; skipped=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# sonda falsa: responde (rc 0) só para os hosts de PROBE_UP (separados por espaço); registra "host porta" em $PROBE_LOG
cat > "$T/probe" <<'EOF'
#!/bin/sh
echo "$1 $2" >> "$PROBE_LOG"
case " ${PROBE_UP:-} " in *" $1 "*) exit 0 ;; esac
exit 1
EOF
chmod +x "$T/probe"
# nc falso: `nc -z HOST PORT`; responde para NC_UP, pendura (exec sleep: o pid que o relógio mata é o do sleep) para NC_HANG, falha no resto
mkdir -p "$T/ncbin" "$T/empty"
cat > "$T/ncbin/nc" <<'EOF'
#!/bin/sh
host=$2
case " ${NC_UP:-} " in *" $host "*) exit 0 ;; esac
case " ${NC_HANG:-} " in *" $host "*) exec sleep 30 ;; esac
exit 1
EOF
chmod +x "$T/ncbin/nc"
# sonda falsa que SEMPRE responde (rc 0), para provar que um host vazio nunca vira "respondeu" nem chega à sonda
cat > "$T/probe-yes" <<'EOF'
#!/bin/sh
echo "$1 $2" >> "$PROBE_LOG"
exit 0
EOF
chmod +x "$T/probe-yes"
# sleep falso + nc falso: o relógio de parede faz `sleep "$s"`; aqui o sleep só REGISTRA o argumento (não espera) e o nc fica de pé até o registro
# existir (teto de 5 s), para que a vigia chegue a rodar antes de ser morta. Assim os segundos que o helper escolheu são lidos, sem depender de tempo.
mkdir -p "$T/sleepbin"
cat > "$T/sleepbin/sleep" <<'EOF'
#!/bin/sh
echo "$1" >> "$SLEEP_LOG"
exit 0
EOF
cat > "$T/sleepbin/nc" <<'EOF'
#!/bin/sh
i=0
while [ ! -s "$SLEEP_LOG" ] && [ "$i" -lt 50 ]; do command -p sleep 0.1; i=$((i+1)); done
exit 0
EOF
chmod +x "$T/sleepbin/sleep" "$T/sleepbin/nc"

# run_host [VAR=val ...]: roda o helper em outro processo; OUT = stdout, RC = rc, EL = segundos de relógio. Limite duro (LIM, 8 s) contra pendurado.
LIM=${MBPH_LIMIT:-8}
run_host() {
  local t0; t0=$(date +%s)
  OUT=$(env PROBE_LOG="$T/probe.log" "$@" ${TMO:+"$TMO" "$LIM"} "${BASH_UNDER:-$BASH}" "$SUT" 2>/dev/null); RC=$?
  EL=$(( $(date +%s) - t0 ))
}
want() { # $1 = esperado · $2 = descrição (usa OUT/RC/EL da última run_host)
  [ "$RC" = 0 ] && [ "$OUT" = "$1" ]; ok $? "$2${DEBUG:+ [got '$OUT' rc=$RC ${EL}s]}"
}

# up_rc <user@host> [VAR=val ...]: roda o _mbp_host_up DIRETO (incluído, em outro processo); UPRC = o rc dele. O helper público não separa "sem evidência" de
# "respondeu" quando o resultado dá o mesmo nome (o Tailscale é o padrão e vale nos dois casos): o rc da função é o que separa.
up_rc() {
  local h="$1"; shift
  UPRC=$(env -u MBP_HOST_PROBE -u MBP_HOST_PROBE_S PROBE_LOG="$T/probe.log" "$@" "${BASH_UNDER:-$BASH}" -c '. "$1"; _mbp_host_up "$2"; echo $?' _ "$SUT" "$h" 2>/dev/null)
}

battery() {
  local out v exp
  : > "$T/probe.log"
  # --- a sonda é um stub (MBP_HOST_PROBE): nada de rede
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP="athoss-macbook-pro athoss-macbook-pro.local"
  want "$TS" "os dois respondem → Tailscale"
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP="athoss-macbook-pro"
  want "$TS" "só o Tailscale responde → Tailscale"
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP="athoss-macbook-pro.local"
  want "$LAN" "o Tailscale mudo e a LAN respondeu → LAN"
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP=""
  want "$TS" "nenhum responde → Tailscale (o padrão inerte, nunca a LAN)"
  run_host MBP_HOST_PROBE="$T/does-not-exist" PROBE_UP="athoss-macbook-pro.local"
  want "$TS" "sonda ausente (não consegui saber) → Tailscale, mesmo com a LAN 'de pé'"
  : > "$T/notexec"; run_host MBP_HOST_PROBE="$T/notexec"
  want "$TS" "sonda inexecutável → Tailscale"
  : > "$T/probe.log"; run_host MBP_HOST_PROBE="$T/probe" PROBE_UP=""
  { grep -qx 'athoss-macbook-pro 22' "$T/probe.log" && grep -qx 'athoss-macbook-pro.local 22' "$T/probe.log"; }; ok $? "a sonda recebe o host SEM usuário e a porta 22 (os dois nomes são sondados)"
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP="alvo-ts" MBP_TS_HOST="u@alvo-ts" MBP_LAN_HOST="u@alvo-lan"
  want "u@alvo-ts" "MBP_TS_HOST troca o nome do Tailscale"
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP="alvo-lan" MBP_TS_HOST="u@alvo-ts" MBP_LAN_HOST="u@alvo-lan"
  want "u@alvo-lan" "MBP_LAN_HOST troca o nome da LAN"
  # --- nc falso no PATH: o relógio de parede (MBP_HOST_PROBE_S=1)
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=1 NC_UP="athoss-macbook-pro"
  want "$TS" "nc: o Tailscale responde → Tailscale"
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=1 NC_UP="athoss-macbook-pro.local"
  want "$LAN" "nc: o Tailscale mudo (recusou) e só a LAN responde → LAN"
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=1 NC_HANG="athoss-macbook-pro" NC_UP="athoss-macbook-pro.local"
  { [ "$OUT" = "$LAN" ] && [ "$EL" -le 4 ]; }; ok $? "nc: Tailscale pendurado + LAN respondeu → LAN, cortado pelo relógio (<= 4 s; foram ${EL}s)"
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=1 NC_HANG="athoss-macbook-pro athoss-macbook-pro.local"
  { [ "$OUT" = "$TS" ] && [ "$EL" -le 4 ]; }; ok $? "nc: as duas penduradas (mDNS) → Tailscale, sem segurar o chamador (<= 4 s; foram ${EL}s)"
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=1 NC_UP="athoss-macbook-pro" NC_HANG="athoss-macbook-pro.local"
  { [ "$OUT" = "$TS" ] && [ "$EL" -le 2 ]; }; ok $? "nc: Tailscale respondeu + LAN pendurada → Tailscale JÁ, sem esperar a LAN (<= 2 s; foram ${EL}s)"
  run_host PATH="$T/ncbin:$PATH" MBP_HOST_PROBE_S=abc NC_HANG="athoss-macbook-pro athoss-macbook-pro.local"
  { [ "$OUT" = "$TS" ] && [ "$EL" -ge 2 ] && [ "$EL" -le 6 ]; }; ok $? "MBP_HOST_PROBE_S ilegível volta a 2 s (foram ${EL}s)"
  run_host PATH="$T/empty" NC_UP="athoss-macbook-pro"
  want "$TS" "sem nc no PATH → Tailscale (sem evidência, não é erro)"
  # --- o rc de _mbp_host_up direto (ga-dw1h9h3, hq-mutants): o que o helper público não mostra
  : > "$T/probe.log"; up_rc "athos@" MBP_HOST_PROBE="$T/probe-yes"
  { [ "$UPRC" = 1 ] && [ ! -s "$T/probe.log" ]; }; ok $? "host vazio nunca é 'respondeu' (rc 1), mesmo com uma sonda que sempre responde, e a sonda nem é chamada"
  : > "$T/probe.log"; up_rc "athos@alvo" MBP_HOST_PROBE="$T/probe-yes"
  { [ "$UPRC" = 0 ] && grep -qx 'alvo 22' "$T/probe.log"; }; ok $? "host com nome e sonda que responde → rc 0 (o caso acima não é vácuo)"
  up_rc "athos@alvo" PATH="$T/empty"
  { [ -n "$UPRC" ] && [ "$UPRC" != 0 ]; }; ok $? "sem nc no PATH e sem sonda: _mbp_host_up NÃO diz 'respondeu' (rc != 0; foi '$UPRC')"
  # os segundos do relógio de parede: inteiro >= 1 vale como veio; ausente, vazio, zero, negativo e lixo voltam a 2
  for v in 1 3 10 0 00 abc -1 ""; do
    case "$v" in 1|3|10) exp="$v" ;; *) exp=2 ;; esac
    : > "$T/sleep.log"; up_rc "athos@alvo" PATH="$T/sleepbin:$PATH" SLEEP_LOG="$T/sleep.log" MBP_HOST_PROBE_S="$v"
    [ "$(cat "$T/sleep.log")" = "$exp" ]; ok $? "MBP_HOST_PROBE_S='$v' → o relógio de parede espera $exp s (foi '$(cat "$T/sleep.log")')"
  done
  : > "$T/sleep.log"; up_rc "athos@alvo" PATH="$T/sleepbin:$PATH" SLEEP_LOG="$T/sleep.log"
  [ "$(cat "$T/sleep.log")" = 2 ]; ok $? "MBP_HOST_PROBE_S ausente → o relógio de parede espera 2 s (foi '$(cat "$T/sleep.log")')"
  # --- forma da saída e uso incluído
  run_host MBP_HOST_PROBE="$T/probe" PROBE_UP=""
  { [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && [ -n "$OUT" ]; }; ok $? "a saída é UMA linha não vazia"
  out=$("${BASH_UNDER:-$BASH}" -c '. "$1"; type mbp_default_host >/dev/null 2>&1 && echo defined' _ "$SUT" 2>&1)
  [ "$out" = defined ]; ok $? "incluído (source) não imprime nada e define mbp_default_host"
}

if [ -z "${MBPH_NO_BATTERY:-}" ]; then
  battery
  if [ -z "${MBPH_ONE:-}" ] && [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt "${BASH_VERSINFO[0]}" ]; then
    echo "-- sob $(/bin/bash -c 'echo bash ${BASH_VERSION}')"
    BASH_UNDER=/bin/bash; battery; unset BASH_UNDER
  fi
fi

mutant() { # $1 = nome · $2 = trecho exato (uma ocorrência) · $3 = troca
  local m="$T/mut-$1.sh" out
  python3 -I -c 'import sys; s=open(sys.argv[1],encoding="utf-8").read(); assert s.count(sys.argv[2])==1, "trecho do mutante não é único"; open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$SUT" "$2" "$3" "$m" || { ok 1 "mutante $1: montagem"; return; }
  out=$(MBPH_UNDER_TEST="$m" MBPH_NO_MUTANTS=1 MBPH_ONE=1 MBPH_LIMIT=4 "$BASH" "$0" 2>&1)
  if printf '%s\n' "$out" | grep -q '^FAIL'; then ok 0 "controle negativo: $1 reprova"; else ok 1 "controle negativo: $1 NÃO reprovou"; fi
}
if [ -z "${MBPH_NO_MUTANTS:-}" ] && [ -z "${MBPH_NO_BATTERY:-}" ]; then
  mutant "nada-respondeu-vira-LAN" $'  printf \'%s\\n\' "$MBP_TS_HOST"\n}' $'  printf \'%s\\n\' "$MBP_LAN_HOST"\n}'
  mutant "tailscale-nao-perguntado" 'if _mbp_host_up "$MBP_TS_HOST"; then' 'if false; then'
  mutant "host-vazio-vira-respondeu" '[ -n "$h" ] || return 1' '[ -n "$h" ] || return 0'
  mutant "sem-nc-vira-respondeu" 'command -v nc >/dev/null 2>&1 || return 1' 'command -v nc >/dev/null 2>&1 || return 0'
  mutant "segundos-validos-viram-2" '[ "$s" -ge 1 ] || s=2' '[ "$s" -ge 1 ] && s=2'
  mutant "um-segundo-vira-2" '[ "$s" -ge 1 ] || s=2' '[ "$s" -gt 1 ] || s=2'
  if [ -n "$TMO" ]; then mutant "sem-relogio-de-parede" 'kill "$pid" 2>/dev/null ) >/dev/null' ': ) >/dev/null'
  else skipped=$((skipped+1)); echo "pulado: controle negativo sem-relogio-de-parede (sem timeout/gtimeout)"; fi
fi
echo "== final: $((n-fails))/$n ok, $skipped sem rodar =="
[ "$fails" = 0 ]
