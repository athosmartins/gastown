#!/bin/bash
# repro-lock-guard.sh (ga-89ix4m4): hook PreToolUse:Edit|Write|MultiEdit|NotebookEdit dos papéis de pool que CONSTROEM (dog, wa-worker, ps-worker; fiado em claude-overlays/pool-roles.json por hooks_extra).
# Recusa (exit 2 + «repro-lock-guard: BLOCKED …» no stderr, que o claude devolve ao modelo) a edição de um arquivo de teste TRAVADO por `repro-lock.py lock`: o teste que reproduz o bug, commitado antes do
# conserto, não pode ser afrouxado junto com ele (o gate confere o mesmo no git, passo 2f; este hook só avisa cedo). Qualquer outra coisa, e toda falha deste script, é exit 0: FAIL-OPEN, porque
# um hook que trava todo Edit/Write de todo worker é pior que o buraco que ele tapa, e quem recusa de verdade é o gate. Mas a falha é CONTADA no log (UNGUARDED), nunca calada.
# Desligar: REPRO_LOCK_HOOK=0 (esta sessão) ou touch $GC_CITY_PATH/.gc/repro-lock-hook.off. Contrato e saída de emergência (release com motivo): docs/runbooks/repro-lock.md
#
# DOIS ESTÁGIOS, porque isto roda em TODO Edit/Write e o python3 leva 100-280 ms no load da cidade (a poll de um detector É carga, ga-y0g5x):
#   1. aqui, em bash + um jq: portão de identidade, e a pergunta «este worktree tem estado de trava?» respondida só olhando <git-dir>/repro-lock. Sem pasta = exit 0 sem python.
#   2. repro-lock.py guard (python -I -S), sob prazo duro: o casamento exato do caminho (realpath, link, maiúscula do APFS) com os arquivos travados.
# O git-dir é achado SEM chamar o git: sobe da pasta do arquivo até um `.git`, que é pasta (clone) ou arquivo «gitdir: <caminho>» (worktree ligado, o caso do pool). repro-lock.py grava o
# estado no mesmo lugar (git rev-parse --absolute-git-dir); o selftest cobre os dois formatos.
#
# QUEM é guardado: só sessão com identidade de pool CONSTRUTOR (GC_TEMPLATE, senão GC_AGENT, senão GC_ALIAS: a PRIMEIRA que existe decide, identidade incoerente passa). Revisor, Mayor, crews e
# quem não tem identidade GC_* passam intactos: o overlay deles nem registra este hook, e se um dia vazar para a cidade, o portão o deixa inerte.
# Ganchos de teste (env): REPRO_LOCK_GUARD_LOG, REPRO_LOCK_GUARD_PY (interpretador), REPRO_LOCK_GUARD_TIMEOUT (segundos, padrão 8).
set -u
BLOCKED="repro-lock-guard: BLOCKED"

who=${GC_TEMPLATE:-${GC_AGENT:-${GC_ALIAS:-}}}
who=${who##*/}
who=${who#gastown.}
note() {   # note <resultado> <motivo>: o log é melhor-esforço, e uma falha ao gravar nunca muda o veredito
  local log="${REPRO_LOCK_GUARD_LOG:-${HOME:-/tmp}/.gastown/logs/repro-lock-guard.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s\tagent=%s\tresult=%s\treason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${who:-none}" "$1" "$2" >> "$log" 2>/dev/null || true
}

# vazio → payload vazio: nada a julgar, e CONTADO abaixo; falhou/ilegível (stdin fechado) → o mesmo: exit 0 com UNGUARDED
input="$(cat 2>/dev/null)" || input=""
[ "${REPRO_LOCK_HOOK:-1}" = 0 ] && exit 0
# vazio (arquivo ausente) → o hook segue LIGADO; falhou (sem GC_CITY_PATH, sem permissão) → idem: um -e que não consegue testar lê «ausente»
[ -e "${GC_CITY_PATH:-/nonexistent}/.gc/repro-lock-hook.off" ] && exit 0
case "$who" in
  dog|dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) ;;
  *) exit 0 ;;
esac
[ -n "$input" ] || { note UNGUARDED "hook input was empty"; exit 0; }
command -v jq >/dev/null 2>&1 || { note UNGUARDED "jq not found on PATH"; exit 0; }

# vazio → sem tool/arquivo: exit 0 (não é Edit de arquivo); falhou/ilegível → o sentinela `ok` não chega e o payload é contado como ilegível
tool=""; file=""; cwd=""; jq_ok=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' file
  IFS= read -r -d '' cwd
  IFS= read -r -d '' jq_ok
} < <(printf '%s' "$input" | jq -j '
    (if type == "object" then . else {} end)
    | (.tool_name | if type == "string" then . else "" end), "\u0000",
      ((.tool_input.file_path? // .tool_input.notebook_path? // "") | if type == "string" then . else "" end), "\u0000",
      (.cwd | if type == "string" then . else "" end), "\u0000",
      "ok", "\u0000"' 2>/dev/null)
[ "$jq_ok" = "ok" ] || { note UNGUARDED "hook input is not parseable JSON (jq rejected it)"; exit 0; }
case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
[ -n "$file" ] || exit 0

# ---- estágio 1: há estado de trava neste worktree? (sem git, sem python) ----
case "$file" in /*) ;; *) file="${cwd:-.}/$file" ;; esac
d="${file%/*}"; [ -n "$d" ] || d=/
while [ ! -d "$d" ] && [ "$d" != / ]; do d="${d%/*}"; [ -n "$d" ] || d=/; done   # Write pode criar a pasta: sobe até a que existe
gd=""
while :; do
  if [ -d "$d/.git" ]; then
    gd="$d/.git"; break
  elif [ -f "$d/.git" ]; then
    line=""
    # vazio → .git sem a linha «gitdir:» = não sei onde mora o estado: sem trava, e CONTADO; falhou/ilegível (sem permissão) → o mesmo
    IFS= read -r line < "$d/.git" 2>/dev/null || line=""
    case "$line" in
      "gitdir: "*) gd="${line#gitdir: }"; case "$gd" in /*) ;; *) gd="$d/$gd" ;; esac ;;
      *) note UNGUARDED ".git file of $d has no gitdir line" ;;
    esac
    break
  fi
  [ "$d" = / ] && break
  d="${d%/*}"; [ -n "$d" ] || d=/
done
[ -n "$gd" ] && [ -d "$gd/repro-lock" ] || exit 0

# ---- estágio 2: o casamento exato, sob prazo duro ----
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || { note UNGUARDED "motor ausente: pasta do script ilegível"; exit 0; }
ENGINE="$HERE/repro-lock.py"
[ -f "$ENGINE" ] || { note UNGUARDED "motor ausente: $ENGINE"; exit 0; }
PY="${REPRO_LOCK_GUARD_PY:-$(command -v python3 2>/dev/null)}"
{ [ -n "$PY" ] && [ -x "$PY" ]; } || { note UNGUARDED "no python3 interpreter"; exit 0; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/repro-lock-guard.XXXXXX" 2>/dev/null)" || { note UNGUARDED "mktemp failed"; exit 0; }
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$input" > "$tmp/in" 2>/dev/null || { note UNGUARDED "could not stage the hook input"; exit 0; }

"$PY" -I -S "$ENGINE" guard < "$tmp/in" > "$tmp/out" 2> "$tmp/err" &
pid=$!
( sleep "${REPRO_LOCK_GUARD_TIMEOUT:-8}"; kill -9 "$pid" ) >/dev/null 2>&1 &
watchdog=$!
# o aviso de job («Killed: 9») é escrito pelo SHELL ao colher o filho: o watchdog é solto (nunca é esperado) e o wait roda num grupo com stderr descartado (mesma razão do home-scan-guard)
disown "$watchdog" 2>/dev/null
{ wait "$pid"; rc=$?; } 2>/dev/null
kill "$watchdog" >/dev/null 2>&1

# rc 2 também é o que o python devolve num erro de uso: só vale como bloqueio com a marca do motor na 1ª linha do stderr (o resto é fail-open contado)
if [ "$rc" -eq 2 ] && [ "$(head -c "${#BLOCKED}" "$tmp/err" 2>/dev/null)" = "$BLOCKED" ]; then
  note BLOCKED "$file"
  cat "$tmp/err" >&2
  exit 2
fi
case "$rc" in
  0) [ -s "$tmp/err" ] && note UNGUARDED "$(head -n 1 "$tmp/err" 2>/dev/null)" ;;   # passou, mas o motor tem o que contar (estado ilegível, arquivo fora de repo)
  137|143) note UNGUARDED "engine timed out after ${REPRO_LOCK_GUARD_TIMEOUT:-8}s and was killed" ;;
  *) note UNGUARDED "engine exited $rc without a block verdict" ;;
esac
exit 0
