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
# CONTROLES NEGATIVOS: mutantes do helper que os casos têm de reprovar: nada respondeu → LAN · o Tailscale nem é perguntado (LAN ganha
#   quando responde) · sem relógio de parede (nc pendurado segura o chamador). Pulado sem timeout/gtimeout no PATH (o mutante pendura).
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

battery() {
  local out
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
  if [ -n "$TMO" ]; then mutant "sem-relogio-de-parede" 'kill "$pid" 2>/dev/null ) >/dev/null' ': ) >/dev/null'
  else skipped=$((skipped+1)); echo "pulado: controle negativo sem-relogio-de-parede (sem timeout/gtimeout)"; fi
fi
echo "== final: $((n-fails))/$n ok, $skipped sem rodar =="
[ "$fails" = 0 ]
