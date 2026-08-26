#!/usr/bin/env bash
# engine-build-preflight.sh (ga-6o4bh) — pre-voo de RECURSOS antes de um build
# do engine gascity (go build / make build em _src-hookfix).
#
# WHY (madrugada 26/08, ga-v7nk4): o pre-voo de entao checava so `df >= 6GB` e
# APROVOU uma janela com 8,19GB livres — mas o build era inseguro assim mesmo:
# GOCACHE vazio (alguem rodou go clean -cache no mesmo dia -> build A FRIO,
# "varios GB"), swap com so 1,4GB livre, e load subindo 21,97 -> 38,81 em
# 20min. Quem executava abortou por MEDICAO MANUAL feita na hora do build, nao
# porque o pre-voo avisou — o pre-voo nao olhava pra nenhum desses tres
# sinais, so pra disco. Relato completo: bd show ga-6o4bh (o bug) e os
# comentarios de ga-v7nk4 (o abort ao vivo, com os numeros exatos).
#
# POR QUE DISCO LIVRE SOZINHO ENGANA: no mesmo container APFS, a memoria
# virtual do macOS e o GOCACHE de um build a frio competem pelo MESMO espaco.
# Um pico de memoria no link de um binario grande (232MB neste caso) forca
# alocacao de swap, que come o disco que o GOCACHE tambem precisa. `df` mede a
# largada, nao a corrida.
#
# WHAT: mede quatro sinais — disco livre, swap livre, estado do GOCACHE
# (frio/quente) e load average (valor + tendencia) — e imprime uma
# RECOMENDACAO. Read-only por construcao: nenhuma chamada de build, install,
# symlink ou kill em lugar nenhum deste arquivo (ver selftest S0, que varre
# isso estaticamente).
#
# NAO AUTOMATIZA O ABORT (decisao explicita do bead de origem, secao "NAO
# ENTRA"): este script nunca inicia nem mata um build. Sempre sai 0 quando
# consegue produzir o relatorio, mesmo que a recomendacao seja negativa — a
# decisao de seguir ou adiar continua sendo de quem executa a janela, que tem
# contexto (urgencia do escopo, supervisao humana etc.) que este script nao
# tem. Ele so garante que essa decisao seja informada pelos 4 numeros, nao
# so pelo disco.
#
# TERCEIRO ESTADO (obrigatorio): se um sinal nao puder ser medido (ferramenta
# ausente, comando falhou), a linha diz "nao consegui verificar" e o veredito
# fica DESCONHECIDO — nunca "OK" por ausencia de sinal. DESCONHECIDO conta
# como reprovacao na recomendacao final, do mesmo jeito que um numero ruim.
#
# Uso:
#   bash engine-build-preflight.sh            # relatorio humano
#   bash engine-build-preflight.sh --json      # uma linha JSON
#   bash engine-build-preflight.sh --selftest  # roda os testes deste arquivo
#
# Thresholds (env-overridable, todos em GB):
#   PREFLIGHT_DISK_FLOOR_GB          (default 6) — doutrina existente
#                                     (docs/runbooks/janela-manutencao-bd-e-engine.md),
#                                     inalterada por este fix.
#   PREFLIGHT_SWAP_FLOOR_GB          (default 3) — a janela de 26/08 foi
#                                     medida insegura com 1,40GB e, de novo,
#                                     com 1,67GB livres (~30min depois, mesma
#                                     madrugada); o piso fica acima dos dois
#                                     pontos ja medidos como inseguros.
#   PREFLIGHT_GOCACHE_WARM_GB        (default 1) — >= isto conta como
#                                     "quente" (ha artefato substancial de
#                                     build anterior).
#   PREFLIGHT_GOCACHE_COLD_EXTRA_GB  (default 3) — folga extra de disco (alem
#                                     do piso) exigida quando o GOCACHE esta
#                                     frio. Base: GOCACHE observado AO VIVO
#                                     nesta mesma maquina em 26/08 ~04:03 -03
#                                     = 2,6G ($(go env GOCACHE), du -sh). Isto
#                                     NAO e a medicao de um build limpo do
#                                     zero (o bead pede "medir uma vez quanto
#                                     um build completo cria") — e a leitura
#                                     real mais proxima disponivel sem
#                                     disparar um build a frio so pra
#                                     calibrar, o que reproduziria o proprio
#                                     risco que este script existe pra
#                                     sinalizar. Recalibrar rodando
#                                     `go clean -cache && time make build` numa
#                                     janela supervisionada e substituindo
#                                     este default pela medicao direta.

set -uo pipefail

# ---------------------------------------------------------------------------
# Parsers puros (recebem a string bruta como argumento — testaveis sem tocar
# o sistema real).
# ---------------------------------------------------------------------------

_parse_swapusage_free_mb() {
  # $1 = saida de `sysctl -n vm.swapusage`, ex.:
  #   "total = 12288.00M  used = 10614.00M  free = 1674.00M  (encrypted)"
  printf '%s' "$1" | grep -oE 'free = [0-9.]+M' | grep -oE '[0-9.]+'
}

_parse_loadavg() {
  # $1 = saida de `sysctl -n vm.loadavg`, ex.: "{ 44.71 44.12 38.52 }"
  printf '%s' "$1" | tr -d '{}' | awk '{print $1, $2, $3}'
}

_num_ge() {
  # true (exit 0) sse $1 >= $2, com ambos numericos e nao-vazios.
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'
}

# ---------------------------------------------------------------------------
# read_* — IO real, cada um com um seam de override PREFLIGHT_TEST_* pra
# testar a logica de decisao sem depender do estado real da maquina.
# ---------------------------------------------------------------------------

# Sentinel a test can pass to force a "measurement failed" reading through an
# override seam. A plain empty override (VAR="") is indistinguishable from
# "not set" under `[ -n ... ]`, so it falls through to the real system probe
# instead of simulating failure — this sentinel is the deliberate way to force
# the DESCONHECIDO path from a test.
_UNKNOWN_SENTINEL='__UNKNOWN__'

read_disk_free_gb() {
  if [ "${PREFLIGHT_TEST_DISK_FREE_GB:-}" = "$_UNKNOWN_SENTINEL" ]; then printf ''; return; fi
  if [ -n "${PREFLIGHT_TEST_DISK_FREE_GB:-}" ]; then
    printf '%s' "$PREFLIGHT_TEST_DISK_FREE_GB"; return
  fi
  local mnt line
  for mnt in /System/Volumes/Data /; do
    line=$(df -g "$mnt" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$line" ] && [ "$line" -eq "$line" ] 2>/dev/null; then
      printf '%s' "$line"; return
    fi
  done
  printf ''
}

read_swap_free_gb() {
  if [ "${PREFLIGHT_TEST_SWAP_FREE_GB:-}" = "$_UNKNOWN_SENTINEL" ]; then printf ''; return; fi
  if [ -n "${PREFLIGHT_TEST_SWAP_FREE_GB:-}" ]; then
    printf '%s' "$PREFLIGHT_TEST_SWAP_FREE_GB"; return
  fi
  local raw mb
  raw=$(sysctl -n vm.swapusage 2>/dev/null)
  [ -z "$raw" ] && { printf ''; return; }
  mb=$(_parse_swapusage_free_mb "$raw")
  [ -z "$mb" ] && { printf ''; return; }
  awk -v m="$mb" 'BEGIN{printf "%.2f", m/1024}'
}

read_gocache_gb() {
  if [ "${PREFLIGHT_TEST_GOCACHE_GB:-}" = "$_UNKNOWN_SENTINEL" ]; then printf ''; return; fi
  if [ -n "${PREFLIGHT_TEST_GOCACHE_GB:-}" ]; then
    printf '%s' "$PREFLIGHT_TEST_GOCACHE_GB"; return
  fi
  local dir kb
  dir=$(go env GOCACHE 2>/dev/null)
  [ -z "$dir" ] && { printf ''; return; }
  if [ ! -d "$dir" ]; then
    printf '0.00'; return   # ausente e um fato conhecido: frio, nao "desconhecido"
  fi
  kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  [ -z "$kb" ] && { printf ''; return; }
  awk -v k="$kb" 'BEGIN{printf "%.2f", k/1024/1024}'
}

read_loadavg() {
  # imprime "L1 L5 L15" ou string vazia
  if [ "${PREFLIGHT_TEST_LOADAVG_RAW:-}" = "$_UNKNOWN_SENTINEL" ]; then printf ''; return; fi
  if [ -n "${PREFLIGHT_TEST_LOADAVG_RAW:-}" ]; then
    _parse_loadavg "$PREFLIGHT_TEST_LOADAVG_RAW"; return
  fi
  local raw
  raw=$(sysctl -n vm.loadavg 2>/dev/null)
  [ -z "$raw" ] && { printf ''; return; }
  _parse_loadavg "$raw"
}

# ---------------------------------------------------------------------------
# Selftest — bash engine-build-preflight.sh --selftest
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

  echo "S0: nunca dispara build/install/kill — varredura estatica"
  _s0_result="$(python3 -c '
import re
path = "'"${BASH_SOURCE[0]}"'"
bad = []
with open(path) as fh:
    for i, line in enumerate(fh, 1):
        code = line.split("#", 1)[0]
        code = re.sub(r"\x27[^\x27]*\x27", "", code)
        code = re.sub(r"\"[^\"]*\"", "", code)
        if re.search(r"\b(go build|make build|launchctl kickstart|kill -|rm -rf|go clean)\b", code):
            bad.append(f"{i}: {line.rstrip()}")
print("\n".join(bad))
')"
  [ -z "$_s0_result" ] && ok "nenhuma chamada de build/kill fora de comentarios/strings" \
    || bad "achei uma possivel chamada de build/abort:\n$_s0_result"

  echo "S1: parsers — fixtures literais"
  [ "$(_parse_swapusage_free_mb 'total = 12288.00M  used = 10614.00M  free = 1674.00M  (encrypted)')" = "1674.00" ] \
    && ok "_parse_swapusage_free_mb" || bad "_parse_swapusage_free_mb"
  [ "$(_parse_loadavg '{ 44.71 44.12 38.52 }')" = "44.71 44.12 38.52" ] \
    && ok "_parse_loadavg" || bad "_parse_loadavg"

  echo "S2: read_* — seams de override"
  [ "$(PREFLIGHT_TEST_DISK_FREE_GB=9 read_disk_free_gb)" = "9" ] \
    && ok "read_disk_free_gb override" || bad "read_disk_free_gb override"
  [ "$(PREFLIGHT_TEST_SWAP_FREE_GB=1.40 read_swap_free_gb)" = "1.40" ] \
    && ok "read_swap_free_gb override" || bad "read_swap_free_gb override"
  [ "$(PREFLIGHT_TEST_GOCACHE_GB=0.00 read_gocache_gb)" = "0.00" ] \
    && ok "read_gocache_gb override" || bad "read_gocache_gb override"
  [ "$(PREFLIGHT_TEST_LOADAVG_RAW='{ 10 10 10 }' read_loadavg)" = "10 10 10" ] \
    && ok "read_loadavg override" || bad "read_loadavg override"
  [ -z "$(PREFLIGHT_TEST_SWAP_FREE_GB='__UNKNOWN__' read_swap_free_gb)" ] \
    && ok "read_swap_free_gb __UNKNOWN__ sentinel forces empty" || bad "sentinel did not force empty"

  echo "S3: os numeros REAIS do incidente ga-v7nk4 NAO podem passar"
  _s3_out=$(PREFLIGHT_TEST_DISK_FREE_GB=8.19 PREFLIGHT_TEST_SWAP_FREE_GB=1.40 \
    PREFLIGHT_TEST_GOCACHE_GB=0 PREFLIGHT_TEST_LOADAVG_RAW='{ 38.81 30 21.97 }' \
    bash "${BASH_SOURCE[0]}" --json)
  printf '%s' "$_s3_out" | grep -q '"recommendation":"NAO RECOMENDADO' \
    && ok "numeros do incidente recomendam NAO RECOMENDADO" \
    || bad "numeros do incidente recomendaram seguir (isto e o bug original): $_s3_out"
  printf '%s' "$_s3_out" | grep -q '"swap_verdict":"ABAIXO"' \
    && ok "swap marcado ABAIXO com 1,40GB livres" || bad "swap nao marcado: $_s3_out"
  printf '%s' "$_s3_out" | grep -q '"gocache_verdict":"FRIO-SEM-FOLGA"' \
    && ok "gocache marcado frio-sem-folga" || bad "gocache nao marcado: $_s3_out"

  echo "S4: leitura saudavel recomenda seguir"
  _s4_out=$(PREFLIGHT_TEST_DISK_FREE_GB=20 PREFLIGHT_TEST_SWAP_FREE_GB=8 \
    PREFLIGHT_TEST_GOCACHE_GB=3 PREFLIGHT_TEST_LOADAVG_RAW='{ 5 5 5 }' \
    bash "${BASH_SOURCE[0]}" --json)
  printf '%s' "$_s4_out" | grep -q '"recommendation":"OK PARA COMECAR' \
    && ok "numeros saudaveis recomendam seguir" \
    || bad "numeros saudaveis nao recomendaram seguir: $_s4_out"

  echo "S5: sinal ilegivel nunca vira OK por ausencia"
  _s5_out=$(PREFLIGHT_TEST_DISK_FREE_GB=20 PREFLIGHT_TEST_SWAP_FREE_GB='__UNKNOWN__' \
    PREFLIGHT_TEST_GOCACHE_GB=3 PREFLIGHT_TEST_LOADAVG_RAW='{ 5 5 5 }' \
    bash "${BASH_SOURCE[0]}" --json)
  printf '%s' "$_s5_out" | grep -q '"swap_verdict":"DESCONHECIDO"' \
    && ok "swap ilegivel vira DESCONHECIDO, nao OK" || bad "swap ilegivel nao marcado certo: $_s5_out"
  printf '%s' "$_s5_out" | grep -q '"recommendation":"NAO RECOMENDADO' \
    && ok "sinal DESCONHECIDO reprova a recomendacao final" \
    || bad "sinal DESCONHECIDO nao deveria deixar passar: $_s5_out"

  echo
  echo "selftest: $PASS ok, $FAIL fail"
  [ "$FAIL" = "0" ]
  exit $?
fi

# ---------------------------------------------------------------------------
# Execucao real
# ---------------------------------------------------------------------------

JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

DISK_FLOOR_GB="${PREFLIGHT_DISK_FLOOR_GB:-6}"
SWAP_FLOOR_GB="${PREFLIGHT_SWAP_FLOOR_GB:-3}"
GOCACHE_WARM_GB="${PREFLIGHT_GOCACHE_WARM_GB:-1}"
GOCACHE_COLD_EXTRA_GB="${PREFLIGHT_GOCACHE_COLD_EXTRA_GB:-3}"

disk_free_gb=$(read_disk_free_gb)
swap_free_gb=$(read_swap_free_gb)
gocache_gb=$(read_gocache_gb)
loadavg=$(read_loadavg)
load1=""; load5=""; load15=""
if [ -n "$loadavg" ]; then read -r load1 load5 load15 <<<"$loadavg"; fi

verdict_disk="DESCONHECIDO"
if [ -n "$disk_free_gb" ]; then
  if _num_ge "$disk_free_gb" "$DISK_FLOOR_GB"; then verdict_disk="OK"; else verdict_disk="ABAIXO"; fi
fi

verdict_swap="DESCONHECIDO"
if [ -n "$swap_free_gb" ]; then
  if _num_ge "$swap_free_gb" "$SWAP_FLOOR_GB"; then verdict_swap="OK"; else verdict_swap="ABAIXO"; fi
fi

verdict_gocache="DESCONHECIDO"
if [ -n "$gocache_gb" ]; then
  if _num_ge "$gocache_gb" "$GOCACHE_WARM_GB"; then
    verdict_gocache="QUENTE"
  elif [ -n "$disk_free_gb" ]; then
    needed=$(awk -v f="$DISK_FLOOR_GB" -v e="$GOCACHE_COLD_EXTRA_GB" 'BEGIN{print f+e}')
    if _num_ge "$disk_free_gb" "$needed"; then verdict_gocache="FRIO-COM-FOLGA"; else verdict_gocache="FRIO-SEM-FOLGA"; fi
  else
    verdict_gocache="FRIO-DISCO-DESCONHECIDO"
  fi
fi

load_trend="desconhecida"
if [ -n "$load1" ] && [ -n "$load15" ]; then
  load_trend=$(awk -v a="$load1" -v b="$load15" \
    'BEGIN{ if (a > b*1.15) print "SUBINDO"; else if (a < b*0.85) print "CAINDO"; else print "ESTAVEL" }')
fi

bad=0
case "$verdict_disk" in OK) ;; *) bad=1 ;; esac
case "$verdict_swap" in OK) ;; *) bad=1 ;; esac
case "$verdict_gocache" in QUENTE|FRIO-COM-FOLGA) ;; *) bad=1 ;; esac

if [ "$bad" = "1" ]; then
  recommendation="NAO RECOMENDADO - pelo menos um sinal reprovou ou nao pode ser medido (ver detalhe acima). Decisao de seguir ou adiar continua sendo de quem executa a janela."
else
  recommendation="OK PARA COMECAR - os 4 sinais medidos passam nos pisos configurados."
  [ "$load_trend" = "SUBINDO" ] && recommendation="$recommendation ATENCAO: load esta SUBINDO -- remeca este pre-voo o mais perto possivel do inicio real do build."
fi

if [ "$JSON_OUT" = "1" ]; then
  json_num() { [ -n "${1:-}" ] && printf '%s' "$1" || printf 'null'; }
  printf '{"disk_free_gb":%s,"disk_floor_gb":%s,"disk_verdict":"%s","swap_free_gb":%s,"swap_floor_gb":%s,"swap_verdict":"%s","gocache_gb":%s,"gocache_warm_floor_gb":%s,"gocache_verdict":"%s","load1":%s,"load5":%s,"load15":%s,"load_trend":"%s","recommendation":"%s"}\n' \
    "$(json_num "$disk_free_gb")" "$DISK_FLOOR_GB" "$verdict_disk" \
    "$(json_num "$swap_free_gb")" "$SWAP_FLOOR_GB" "$verdict_swap" \
    "$(json_num "$gocache_gb")" "$GOCACHE_WARM_GB" "$verdict_gocache" \
    "$(json_num "$load1")" "$(json_num "$load5")" "$(json_num "$load15")" "$load_trend" \
    "$recommendation"
  exit 0
fi

echo "=== PRE-VOO DE RECURSOS - build do engine (ga-6o4bh) ==="
echo
if [ -n "$disk_free_gb" ]; then
  echo "  1. Disco livre ... ${disk_free_gb}GB (minimo ${DISK_FLOOR_GB}GB)              $verdict_disk"
else
  echo "  1. Disco livre ... nao consegui verificar (df falhou)                    DESCONHECIDO"
fi
if [ -n "$swap_free_gb" ]; then
  echo "  2. Swap livre .... ${swap_free_gb}GB (minimo ${SWAP_FLOOR_GB}GB)              $verdict_swap"
else
  echo "  2. Swap livre .... nao consegui verificar (sysctl vm.swapusage falhou)   DESCONHECIDO"
fi
if [ -n "$gocache_gb" ]; then
  echo "  3. GOCACHE ....... ${gocache_gb}GB (quente >= ${GOCACHE_WARM_GB}GB)           $verdict_gocache"
else
  echo "  3. GOCACHE ....... nao consegui verificar (go env / du falhou)           DESCONHECIDO"
fi
if [ -n "$load1" ]; then
  echo "  4. Load avg ...... 1m=$load1  5m=$load5  15m=$load15  -- tendencia: $load_trend"
else
  echo "  4. Load avg ...... nao consegui verificar (sysctl vm.loadavg falhou)     DESCONHECIDO"
fi
echo
echo "  RECOMENDACAO: $recommendation"
echo "  (script somente-leitura: nunca inicia nem aborta um build por conta"
echo "   propria — so mede e recomenda.)"

if [ -z "$disk_free_gb" ] && [ -z "$swap_free_gb" ] && [ -z "$gocache_gb" ] && [ -z "$load1" ]; then
  exit 2
fi
exit 0
