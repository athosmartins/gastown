#!/bin/sh
# pytest-shim.sh — o pytest dirigido dos workers e das crews vai ao MacBook Pro quando ele está saudável, e roda aqui quando não (ga-fl2nek).
#
# Contents
#   Por quê · Como entra no PATH · O que intercepta · Quando NÃO intercepta · Resultado · Chaves e log
#
# POR QUÊ (épico ga-sokx7u): medido em 12/10, desde 11/10 21:08 só 14 rodadas de pytest dos workers foram ao MBP — a linha do preâmbulo
#   (ga-yvs19w) pede que o worker chame scripts/mbp-run.sh, e quase nenhum chama; o mini roda com load ~55 e o MBP com ~6. Este atalho tira a
#   decisão do worker: o comando que ele já digita (`pytest ...`, `python3 -m pytest ...`) passa a ser o caminho com MBP.
#
# COMO ENTRA NO PATH: scripts/pytest-shim/bin/{pytest,python3,python} são três symlinks para este arquivo; o NOME com que o shell o chamou diz qual comando
#   o worker digitou. Quem põe esse diretório NA FRENTE do PATH é um hook SessionStart (CLAUDE_ENV_FILE) — nos workers de pool, pelo overlay gerado de
#   pool-roles.json; nas crews, por scripts/pytest-shim-activate.sh. Nada aqui é instalado em /usr/local ou em venv: sem o hook, o atalho não existe.
#   Um shell só, sem subshell no caminho comum: este arquivo roda em TODA chamada de python3 do worker. Medido num mini com load alto: com um stub que chamava
#   outro shell e três `$(...)` a chamada custava 25-45 ms a mais; python3 que não é pytest passa direto, sem fork nem escrita.
#
# O QUE INTERCEPTA — medido em 601 chamadas de Bash dos workers e crews em 14 dias: `python3 -m pytest` é a forma dominante (288) e
#   `venv/bin/python -m pytest` a segunda (161); o `pytest` solto é minoria. Por isso `python3`/`python` olham os argumentos e só desvia
#   `[opções do python] -m pytest ...` (também `-mpytest`); qualquer outra coisa executa o python de verdade, com os mesmos argumentos e o mesmo
#   stdin. LIMITE CONHECIDO: `venv/bin/python -m pytest` (caminho explícito) NÃO passa pelo PATH e não é desviado por este atalho.
#
# QUANDO NÃO INTERCEPTA (roda o comando de hoje, sem nenhuma saída a mais):
#   atalho já ativo (execução aninhada, ex.: um teste que chama python3 -m pytest) · GC_PYTEST_SHIM=off no comando · offload desligado
#   (falta $CITY/.gc/mbp-offload.on) ou pausado ($CITY/.gc/mbp-offload.pause) · chave $CITY/.gc/pytest-shim.off · nenhum argumento que possa ser
#   alvo de teste (`pytest`, `pytest --version`, `pytest -h`). O resto da decisão (MBP sem saúde, slots cheios, alvo que lê shared/data, flag que
#   depende do disco daqui, diretório como alvo, suíte inteira) é do gate-pytest.sh, que cai em "rodar aqui" com o motivo.
#
# RESULTADO: quem decide onde roda e em que resultado acreditar é o scripts/gate-pytest.sh (mesma política do revisor do gate: só verde do MBP
#   vale; vermelho e pulado do MBP são reconferidos aqui; saída que não se sabe ler roda tudo aqui). O rc que o worker vê é o do pytest, nunca
#   96..99, e uma falha de teste NUNCA vira zero. A última linha impressa é `pytest-shim: ran=mbp|local|mbp+local rc=N secs=N ...`. Se o
#   gate-pytest.sh sumir ou não abrir, o comando roda aqui como hoje e o stderr diz isso (nunca um atalho que quebra o pytest do worker).
#   O verde do MBP traz a `nota:` do gate (o MBP não tem shared/data nem .env); para rodar um arquivo aqui só naquele comando:
#   `GC_PYTEST_SHIM=off python3 -m pytest <arquivo>`.
#
# CHAVES E LOG: `touch $CITY/.gc/pytest-shim.off` desliga SÓ este atalho (apague para religar; o gate e o mbp-run seguem como estão) e
#   `mbp-offload.sh off` desliga tudo. $CITY/.gc/logs/pytest-shim.jsonl recebe uma linha por execução desviada (as do gate-pytest.sh:
#   ts, session, repo, ran, rc, secs, detail) e uma por execução que o atalho deixou passar (`"src":"shim-pass"`, `"ran":"local"`, `detail` =
#   o motivo; sem rc, porque o processo é substituído pelo pytest). Contagem de aceite: runbook docs/runbooks/mbp-offload.md, seção do atalho.
#   Ajustes por ambiente: PYTEST_SHIM_CITY, PYTEST_SHIM_GATE (caminho do gate-pytest.sh).

# Chamado por um symlink bin/<nome> -> ../pytest-shim.sh: o nome do symlink é o comando do worker. Chamado direto (selftest, `sh pytest-shim.sh`), SHIM_AS manda.
case "$0" in */*) _me=${0%/*} ;; *) _me=. ;; esac
case "$_me" in
  bin|*/bin) BIN_DIR=$_me; SELF_DIR=${_me%bin}; SELF_DIR=${SELF_DIR%/}; SELF_DIR=${SELF_DIR:-.}; SHIM_AS=${0##*/} ;;
  *)         SELF_DIR=$_me; BIN_DIR=$_me/bin; SHIM_AS=${SHIM_AS:-pytest} ;;
esac
CITY=${PYTEST_SHIM_CITY:-${GC_CITY_PATH:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}}
LOG="$CITY/.gc/logs/pytest-shim.jsonl"
REAL=""; SKIP=0; SHEBANG_PY=""

# REAL = o primeiro executável `$1` do PATH que não seja o diretório deste atalho (nem outro nome para o mesmo arquivo: PATH com o diretório duas
# vezes, ou por um symlink, não pode virar recursão). Não acha → alguns lugares conhecidos; não acha nada → rc 1. Sem subshell: o resultado vai na variável.
find_real() {
  REAL=""
  _fr_old=$IFS; IFS=:
  for _fr_d in $PATH; do
    [ -n "$_fr_d" ] || continue
    [ "$_fr_d" = "$BIN_DIR" ] && continue
    [ -f "$_fr_d/$1" ] && [ -x "$_fr_d/$1" ] || continue
    [ "$_fr_d/$1" -ef "$BIN_DIR/$1" ] && continue
    IFS=$_fr_old; REAL="$_fr_d/$1"; return 0
  done
  IFS=$_fr_old
  for _fr_d in /opt/homebrew/bin /usr/local/bin /usr/bin; do
    [ -f "$_fr_d/$1" ] && [ -x "$_fr_d/$1" ] && [ ! "$_fr_d/$1" -ef "$BIN_DIR/$1" ] && { REAL="$_fr_d/$1"; return 0; }
  done
  return 1
}

# SHEBANG_PY = o interpretador python do shebang de `$1` (o `pytest` de verdade é um script cujo shebang diz com que python ele roda), ou vazio. Só vale um
# interpretador chamado python* — direto (`#!/opt/homebrew/.../python3.11`) ou por `env` (`#!/usr/bin/env python3`, opções e VAR=valor do env
# puladas). Um shebang de shell (`#!/bin/sh`) ou de qualquer outro programa NÃO é python: usá-lo daria `sh -m pytest` no lugar do pytest.
shebang_python() {
  SHEBANG_PY=""
  _sp_line=$(head -n 1 "$1" 2>/dev/null)
  case "$_sp_line" in "#!"*) ;; *) return 1 ;; esac
  _sp_line=${_sp_line#\#!}
  _sp_old=$IFS; IFS=' 	'; set -f; set -- $_sp_line; set +f; IFS=$_sp_old    # só os parâmetros posicionais DESTA função
  [ $# -gt 0 ] || return 1
  case "${1##*/}" in
    env)
      shift
      while [ $# -gt 0 ]; do case "$1" in -*|*=*) shift ;; *) break ;; esac; done
      [ $# -gt 0 ] || return 1
      case "${1##*/}" in python*) find_real "${1##*/}" && SHEBANG_PY=$REAL ;; *) return 1 ;; esac ;;
    python*) [ -x "$1" ] && SHEBANG_PY=$1 ;;
    *) return 1 ;;
  esac
  [ -n "$SHEBANG_PY" ]
}

# Linha do log para uma execução que o atalho deixou passar. Falhar ao gravar nunca atrapalha o comando.
log_pass() { # $1 = motivo
  { mkdir -p "$CITY/.gc/logs" && printf '{"ts":"%s","src":"shim-pass","session":"%s","ran":"local","detail":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GC_SESSION_NAME:-}" "$1" >> "$LOG"; } 2>/dev/null
  return 0
}

run_real() { # $1 = nome; o resto são os argumentos ORIGINAIS
  _rr_name=$1; shift
  find_real "$_rr_name" || { printf '%s: command not found\n' "$_rr_name" >&2; exit 127; }
  exec "$REAL" "$@"
}

# SKIP = quantos argumentos do python vêm até `pytest` (inclusive), ou 0 se não for `-m pytest`. Só olha as opções do INTERPRETADOR: o primeiro argumento
# que não é opção (um script, `-`) encerra a leitura, e `-c <código>` nunca é módulo. Opções que levam valor separado: -W, -X, --check-hash-based-pycs.
py_pytest_skip() {
  SKIP=0; _pp_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -m)         [ "${2:-}" = pytest ] && SKIP=$((_pp_n + 2)); return 0 ;;
      -mpytest)   SKIP=$((_pp_n + 1)); return 0 ;;
      -c|-c?*)    return 0 ;;
      -W|-X|--check-hash-based-pycs) [ $# -ge 2 ] || return 0; shift 2; _pp_n=$((_pp_n + 2)) ;;
      -?*)        shift; _pp_n=$((_pp_n + 1)) ;;
      *)          return 0 ;;
    esac
  done
  return 0
}

# ---- o que o worker digitou ----------------------------------------------------------------------------------------------------------------
case "$SHIM_AS" in
  pytest) ;;
  python|python3) py_pytest_skip "$@" ;;
  *) run_real "$SHIM_AS" "$@" ;;
esac
if [ "$SHIM_AS" != pytest ] && [ "$SKIP" -eq 0 ]; then run_real "$SHIM_AS" "$@"; fi   # python que não é `-m pytest`: o caminho mais quente, sem log

# Daqui para baixo é uma chamada de pytest. Os argumentos do pytest são os que sobram depois de `-m pytest` (no python) ou todos (no stub pytest);
# "$@" continua sendo o comando ORIGINAL até o último passo, para que todo `run_real` rode exatamente o que o worker digitou.

# Motivos de deixar passar. Os dois primeiros são silenciosos e sem log (aninhado: o teste que roda pytest dentro de pytest; bypass: o worker
# pediu); os demais gravam uma linha para a contagem de aceite.
[ -n "${GC_PYTEST_SHIM_ACTIVE:-}" ] && run_real "$SHIM_AS" "$@"
[ "${GC_PYTEST_SHIM:-}" = off ] && run_real "$SHIM_AS" "$@"
PASS=""
[ -f "$CITY/.gc/mbp-offload.on" ] || PASS="offload-desligado"
[ -z "$PASS" ] && [ -e "$CITY/.gc/mbp-offload.pause" ] && PASS="offload-pausado"
[ -z "$PASS" ] && [ -f "$CITY/.gc/pytest-shim.off" ] && PASS="chave-pytest-shim-off"
if [ -z "$PASS" ]; then
  # alvo possível = algum argumento do pytest que não começa com `-`; sem nenhum (`pytest`, `--version`, `-h`) não há o que mandar ao MBP
  shift_n=0; [ "$SHIM_AS" != pytest ] && shift_n=$SKIP
  i=0; has_target=0
  for a in "$@"; do
    i=$((i + 1)); [ $i -le $shift_n ] && continue
    case "$a" in -*) ;; *) has_target=1; break ;; esac
  done
  [ $has_target -eq 1 ] || PASS="sem-alvo"
fi
# o gate-pytest.sh mora uma pasta acima do diretório do atalho (caminho físico: o PATH pode ter chegado aqui por um symlink)
GATE=${PYTEST_SHIM_GATE:-$(cd "$SELF_DIR" 2>/dev/null && pwd -P)/../gate-pytest.sh}
[ -z "$PASS" ] && { [ -f "$GATE" ] && [ -r "$GATE" ] || PASS="gate-pytest-ilegivel"; }
if [ -n "$PASS" ]; then
  [ "$PASS" = gate-pytest-ilegivel ] && printf 'pytest-shim: AVISO: %s ausente ou ilegível — rodando aqui, como sem o atalho\n' "$GATE" >&2
  log_pass "$PASS"
  run_real "$SHIM_AS" "$@"
fi

# ---- desvia para o gate-pytest.sh --------------------------------------------------------------------------------------------------------
# O python que roda o pytest AQUI (quando o gate manda rodar local) é o que o worker teria usado sem o atalho: o próprio python de verdade, ou, no
# stub `pytest`, o interpretador do shebang do `pytest` de verdade (cai no python3 do PATH se o shebang não for um caminho que abre).
real_py=""
case "$SHIM_AS" in
  pytest)
    if find_real pytest && shebang_python "$REAL"; then real_py=$SHEBANG_PY; fi
    [ -n "$real_py" ] || { find_real python3 && real_py=$REAL; } ;;
  *) find_real "$SHIM_AS" && real_py=$REAL ;;
esac
if [ -z "$real_py" ]; then
  # sem python de verdade não há como rodar nem aqui: o comando original dá o erro de "não achei" que o worker veria sem o atalho
  log_pass "python-ausente"; run_real "$SHIM_AS" "$@"
fi

[ "$SHIM_AS" != pytest ] && shift "$SKIP"     # só agora: tira `[opções] -m pytest`; ficam os argumentos do pytest
export GC_PYTEST_SHIM_ACTIVE=1
export GATE_PYTEST_PY="$real_py"
export GATE_PYTEST_LOG="$LOG"
export GATE_PYTEST_OFF_FILE="$CITY/.gc/pytest-shim.off"
export GATE_PYTEST_TAG=pytest-shim
export GATE_PYTEST_LOCAL_HINT='GC_PYTEST_SHIM=off python3 -m pytest <arquivo> (o atalho do pytest manda para o MBP; esta variável o desliga só nesse comando)'
exec /usr/bin/env bash "$GATE" -- "$@"
