#!/usr/bin/env bash
# session-new-bounded.lib.sh — um teto de tempo para `gc session new` nos dispatchers do gate (ga-29ssni).
#
# POR QUE EXISTE: `gc session new` fala com o Dolt, e sob carga ele demora (~50 s medidos, 15-70 s nos logs do gate)
# — mas sem teto, um Dolt que não responde o pendura PARA SEMPRE. O Pilot já embrulha os seus spawns com
# `timeout 150` (PILOT_SPAWN_TIMEOUT_SECS); o quality-gate-dispatcher (3 spawns) e o refino-gate-dispatcher (1 spawn)
# não tinham nada: o processo ficava preso, o launchd não dispara de novo enquanto a execução anterior não termina,
# e o gate inteiro parava até alguém dar kickstart. Esta lib põe o mesmo teto nos quatro.
#
# COMO USAR (sourced, nunca executado; herda o `set -euo pipefail` de quem a carrega):
#     SESSION_JSON=$(gate_bounded_spawn gc --city "$GC_CITY" session new gate-reviewer ... 2>"$err" || echo "{}")
# `gate_bounded_spawn` é um prefixo: o resto da linha, o `2>arquivo` e o `|| echo "{}"` ficam exatamente como estavam.
#
# O QUE FAZ:
#   - roda o comando sob `timeout -k $GATE_SPAWN_KILL_AFTER_SECS $GATE_SPAWN_TIMEOUT_SECS` (padrão 150 s, como o Pilot);
#   - se o teto estourar, escreve no STDERR (que o chamador já captura num arquivo) uma linha começando por
#     `spawn_timeout:` e devolve o rc do timeout — o chamador segue o caminho de "spawn falhou" que já existia;
#   - NÃO tenta de novo sozinho. Exit 124 é o `timeout` matando o CLI, NÃO "a sessão não foi criada": o `gc session new`
#     cria o bead da sessão ANTES de terminar (medido pelo Pilot, ga-oa004t), então a sessão pode existir. Retry cego
#     abriria uma segunda. Por isso `gate_spawn_err_is_timeout` existe: o laço de retry em processo do gate o usa para
#     NÃO repetir; quem decide o próximo passo é o requeue entre varreduras (que já tem teto de tentativas).
#
# TRÊS ESTADOS que esta lib distingue (e nunca colapsa):
#   rodou e terminou  → rc do próprio comando, stdout/stderr intactos;
#   estourou o teto   → rc 124 (ou 137 depois de `-k`, só quando o relógio prova que foi o teto) + linha `spawn_timeout:`;
#   não deu pra impor o teto (sem `timeout`/`gtimeout` no PATH, ou o comando é uma função de shell) → roda SEM teto,
#     como era antes desta lib. Sem o binário, o aviso sai no carregamento (stderr de quem fez o `source`); função de
#     shell só existe nos selftests e passa em silêncio. Sem teto é o estado de hoje; derrubar todo spawn do gate por
#     falta de um binário seria pior que o bug que esta lib corrige.

# Segundos até o teto. Só inteiro >= 1; vazio, texto ou 0 voltam ao padrão — `timeout 0` quer dizer "sem limite" e um
# valor não numérico faria o `timeout` recusar rodar o `gc` (rc 125), então nenhum dos dois pode chegar lá.
GATE_SPAWN_TIMEOUT_SECS="${GATE_SPAWN_TIMEOUT_SECS:-150}"
case "$GATE_SPAWN_TIMEOUT_SECS" in ''|*[!0-9]*) GATE_SPAWN_TIMEOUT_SECS=150 ;; esac
[ "$GATE_SPAWN_TIMEOUT_SECS" -ge 1 ] || GATE_SPAWN_TIMEOUT_SECS=150

# Depois do SIGTERM, quanto esperar antes do SIGKILL (um `gc` que ignora TERM não pode escapar do teto).
GATE_SPAWN_KILL_AFTER_SECS="${GATE_SPAWN_KILL_AFTER_SECS:-10}"
case "$GATE_SPAWN_KILL_AFTER_SECS" in ''|*[!0-9]*) GATE_SPAWN_KILL_AFTER_SECS=10 ;; esac
[ "$GATE_SPAWN_KILL_AFTER_SECS" -ge 1 ] || GATE_SPAWN_KILL_AFTER_SECS=10

# MARCADOR: a linha que gate_bounded_spawn escreve no stderr começa por `spawn_timeout:` e é isso que o chamador procura.
# O texto fica LITERAL, escrito à mão nos dois lugares (aqui, no `echo`, e em gate_spawn_err_is_timeout), e não numa
# variável: uma função exportada (`export -f`, como os selftests do gate fazem) chega a um bash filho SEM as variáveis
# do pai, e `*"$VAR"*` com VAR vazio vira `**` — casaria QUALQUER erro como se fosse timeout. Não pode conter nenhum
# dos trechos que is_transient_spawn_error() do gate já casa ("i/o timeout", "invalid connection", ...): a classificação
# é decisão explícita do gate, não efeito colateral de um texto parecido. session-new-bounded.selftest.sh trava os
# textos iguais entre esta lib e o gate.

# Qual binário impõe o teto. vazio → nenhum dos dois no PATH (estado "não deu pra impor", avisa e roda sem teto);
# falhou → `command -v` não falha de outro jeito: ou acha ou não acha.
GATE_SPAWN_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
if [ -z "$GATE_SPAWN_TIMEOUT_BIN" ]; then
  echo "WARN: ga-29ssni: nem 'timeout' nem 'gtimeout' no PATH — 'gc session new' roda SEM teto de tempo (um Dolt pendurado prende o dispatcher)" >&2
fi

# gate_spawn_err_is_timeout <texto-do-stderr> — "1" se o spawn estourou o teto, "0" se não (inclui texto vazio).
gate_spawn_err_is_timeout() {
  case "${1:-}" in
    *"spawn_timeout:"*) printf '1' ;;
    *) printf '0' ;;
  esac
}

# gate_bounded_spawn <comando> [args...] — roda o comando com o teto; ver o cabeçalho.
gate_bounded_spawn() {
  local _rc=0 _t0 _kind
  # vazio → sem comando algum: devolve 127 sem rodar nada (o `|| echo "{}"` do chamador vira o JSON vazio de sempre);
  # falhou/ilegível → `type -t` falhando ou voltando vazio cai em "não é arquivo", ou seja, roda direto SEM teto.
  [ "$#" -gt 0 ] || return 127
  _kind="$(type -t "$1" 2>/dev/null || true)"
  # Função de shell (os selftests simulam o `gc` assim) não dá para passar ao `timeout`, que executa binário externo.
  # Em produção o `gc` é sempre um arquivo, então este desvio só serve aos mocks.
  if [ "$_kind" != "file" ] || [ -z "$GATE_SPAWN_TIMEOUT_BIN" ]; then
    "$@" || return $?
    return 0
  fi
  _t0=$SECONDS
  "$GATE_SPAWN_TIMEOUT_BIN" -k "$GATE_SPAWN_KILL_AFTER_SECS" "$GATE_SPAWN_TIMEOUT_SECS" "$@" || _rc=$?
  if [ "$_rc" -eq 124 ] || { [ "$_rc" -eq 137 ] && [ $(( SECONDS - _t0 )) -ge "$GATE_SPAWN_TIMEOUT_SECS" ]; }; then
    echo "spawn_timeout: '$1 ...' passou de ${GATE_SPAWN_TIMEOUT_SECS}s (exit=${_rc}) — desfecho DESCONHECIDO: a sessão pode já ter sido criada; sem retry em processo (ga-29ssni)" >&2
  fi
  return "$_rc"
}
