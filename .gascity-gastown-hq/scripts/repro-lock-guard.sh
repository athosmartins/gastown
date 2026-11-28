#!/bin/bash
# repro-lock-guard.sh (ga-89ix4m4): hook PreToolUse:Edit|Write|MultiEdit|NotebookEdit dos construtores de pool (dog, wa-worker; hooks_extra em claude-overlays/pool-roles.json). Recusa (exit 2 + «repro-lock-guard: BLOCKED …» no
# stderr) a edição de arquivo de teste TRAVADO por `repro-lock.py lock` (a trava vem da história git, a MESMA que o gate confere no passo 2f). FAIL-OPEN em tudo, mas CONTADO (UNGUARDED no log): um hook que trava todo Edit/Write é pior
# que o buraco que tapa. Só sessão com identidade de construtor (GC_TEMPLATE, senão GC_AGENT, senão GC_ALIAS). Desligar: REPRO_LOCK_HOOK=0 ou touch $GC_CITY_PATH/.gc/repro-lock-hook.off. Ganchos de teste: REPRO_LOCK_GUARD_LOG, REPRO_LOCK_GUARD_PY. Contrato: docs/runbooks/repro-lock.md.
set -u
BLOCKED="repro-lock-guard: BLOCKED"
who=${GC_TEMPLATE:-${GC_AGENT:-${GC_ALIAS:-}}}; who=${who##*/}; who=${who#gastown.}
note() {   # o log é melhor-esforço: uma falha ao gravar nunca muda o veredito
  local log="${REPRO_LOCK_GUARD_LOG:-${HOME:-/tmp}/.gastown/logs/repro-lock-guard.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null && printf '%s\tagent=%s\tresult=%s\treason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${who:-none}" "$1" "$2" >> "$log" 2>/dev/null
}
# vazio (arquivo ausente) → o hook segue LIGADO; falhou (sem GC_CITY_PATH, sem permissão) → idem: um -e que não consegue testar lê «ausente»
if [ "${REPRO_LOCK_HOOK:-1}" = 0 ] || [ -e "${GC_CITY_PATH:-/nonexistent}/.gc/repro-lock-hook.off" ]; then exit 0; fi
case "$who" in dog|dog-*|wa-worker|wa-worker-*) ;; *) exit 0 ;; esac
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/repro-lock.py"
PY="${REPRO_LOCK_GUARD_PY:-$(command -v python3 2>/dev/null)}"
[ -f "$ENGINE" ] || { note UNGUARDED "motor ausente: $ENGINE"; exit 0; }
{ [ -n "$PY" ] && [ -x "$PY" ]; } || { note UNGUARDED "no python3 interpreter"; exit 0; }
# vazio → payload vazio: nada a julgar, e CONTADO; falhou/ilegível (stdin fechado) → o mesmo: exit 0 com UNGUARDED
input="$(cat 2>/dev/null)" || input=""
[ -n "$input" ] || { note UNGUARDED "hook input was empty"; exit 0; }
err="$(printf '%s' "$input" | "$PY" -I -S "$ENGINE" guard 2>&1 >/dev/null)"; rc=$?
# rc 2 também é o que o python devolve num erro de uso: só vale como bloqueio com a marca do motor no começo do stderr (o resto é fail-open contado)
if [ "$rc" -eq 2 ] && [ "${err:0:${#BLOCKED}}" = "$BLOCKED" ]; then note BLOCKED "${err%%$'\n'*}"; printf '%s\n' "$err" >&2; exit 2; fi
{ [ "$rc" -eq 0 ] && [ -z "$err" ]; } || note UNGUARDED "rc=$rc ${err%%$'\n'*}"   # passou, mas o motor tem o que contar (fora de repo, sem origin/main) ou saiu com código inesperado
exit 0
