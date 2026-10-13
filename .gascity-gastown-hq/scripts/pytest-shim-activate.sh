#!/usr/bin/env bash
# pytest-shim-activate.sh (ga-fl2nek, ga-7q35xn) — registra, de forma idempotente, os hooks do atalho de pytest nas CREWS (oracle, digo, peter, thies, mila, batista…),
# compondo com os hooks que já estão lá: o SessionStart que põe scripts/pytest-shim/bin na frente do PATH dos comandos Bash e o PreToolUse que reescreve
# `venv/bin/python -m pytest` para passar pelo atalho (venv-rewrite-hook.py).
#
# Contents
#   Por quê um script · O que escreve · Alvos · Estados · Uso
#
# POR QUÊ UM SCRIPT: os workers de pool recebem o hook pelo overlay gerado de pool-roles.json (pool-preamble-build.py). As crews não têm overlay gerado: os
#   .claude/settings.json delas são por rig, ignorados pelo git, então o hook ativo nunca será um commit. Este script versionado e re-executável é o substituto
#   (mesma razão e mesmo formato de home-scan-guard-activate.sh): rode uma vez para ativar, e de novo sempre que um reset de rig / `gc init` regerar um
#   settings.json. MERGED != LIVE: `--check` prova o que cada crew lê, e uma sessão de crew só pega o hook ao (re)nascer ou ao compactar (SessionStart).
#   Decisão do Athos (12/10, AskUserQuestion do Mayor, citada no comentário de ga-fl2nek): o pytest pesado das crews também vai ao MacBook, sob a regra da
#   ga-77c1qg (100% com ele fora, prioridade de fundo com ele usando); as crews seguem livres para não usar (GC_PYTEST_SHIM=off no comando).
#
# O QUE ESCREVE: UMA entrada dedicada por evento que o manifesto define (hoje SessionStart e PreToolUse) — {"matcher": <o do manifesto>, "hooks": [<o hook do manifesto>]}.
#   * A FONTE ÚNICA dos matchers e dos comandos é common.hooks_extra_defs["pytest-shim"] de claude-overlays/pool-roles.json (a mesma que gera o overlay dos
#     workers): crews e workers convergem na MESMA entrada byte a byte, e mudar o comando num lugar só muda nos dois. `{gt_root}` é trocado por paths.gt_root.
#   * entrada com matcher PRÓPRIO, nunca dobrada na entrada do `gc prime --hook`: o motor mescla hooks por identidade de matcher (internal/overlay/merge.go
#     hookEntryKey) e uma entrada com o matcher igual SUBSTITUI a do workdir no lugar.
#   * o comando é fail-open (`[ -n "$CLAUDE_ENV_FILE" ] && [ -x "$D/python3" ] || exit 0`): checkout sem o atalho = no-op, nunca um erro de hook por sessão.
#
# MERGE: todo hook cujo comando contém o marcador "pytest-shim" é NOSSO. A PRIMEIRA entrada com o nosso matcher é a dedicada e converge no lugar (o nosso
#   hook é trocado pelo atual onde estava, ou acrescentado; cópias extras somem); todo hook que NÃO é nosso fica onde estava. Nas outras entradas só saem
#   os nossos (uma ativação antiga, uma segunda entrada com o mesmo matcher) e a entrada só some se ficou vazia. Nada que não é nosso é alterado ou reordenado.
#
# ALVOS (sem argumentos): ${PYTEST_SHIM_RIGS_ROOT:-/Users/athos/gt}/*/crew/.claude/settings.json e */crew/*/.claude/settings.json. DE PROPÓSITO fora:
#   a raiz da cidade e o overlay-base `pool` (um hook ali chegaria ao Mayor, ao dog, aos revisores e a todo wisp — o atalho é só de quem roda pytest de
#   trabalho: workers de pool pelo overlay de papel, crews por aqui) e witness/refinery (não são o alvo da decisão do Athos).
#
# TRÊS ESTADOS: ACTIVE (registrado e o atalho existe) · INERT (registrado, mas $GT_ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin/python3 ou venv-rewrite-hook.py não
#   existe: os hooks são um no-op até o merge chegar à checkout principal) · NOT-ACTIVE (alguma entrada não está, ou difere da fonte). `--check` sai 1 em INERT e em NOT-ACTIVE.
#
# USO: pytest-shim-activate.sh [--check] [settings.json ...]   (sem caminhos: os alvos acima). Um alvo ilegível nunca para os outros; a saída é 1 se algum falhou.
#   Ajustes por ambiente (testes): PYTEST_SHIM_RIGS_ROOT, PYTEST_SHIM_MANIFEST, PYTEST_SHIM_GT_ROOT (default: paths.gt_root do manifesto).
set -uo pipefail

RIGS_ROOT="${PYTEST_SHIM_RIGS_ROOT:-/Users/athos/gt}"
MANIFEST="${PYTEST_SHIM_MANIFEST:-$RIGS_ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json}"
MARKER="pytest-shim"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 1; }
[ -r "$MANIFEST" ] || { echo "FATAL: manifesto ilegível: $MANIFEST" >&2; exit 1; }
GT_ROOT="${PYTEST_SHIM_GT_ROOT:-$(jq -r '.paths.gt_root // empty' "$MANIFEST" 2>/dev/null)}"
[ -n "$GT_ROOT" ] || { echo "FATAL: sem paths.gt_root no manifesto (nem PYTEST_SHIM_GT_ROOT)" >&2; exit 1; }
# a definição ÚNICA: um item {event, matcher, hook} por evento do manifesto, com {gt_root} resolvido. Falta ou formato errado = FATAL (nunca um hook inventado aqui).
DEFS=$(jq -c --arg g "$GT_ROOT" '[.common.hooks_extra_defs["pytest-shim"].hooks | to_entries[] | .key as $ev | .value[0] | {event: $ev, matcher, hook: (.hooks[0] | .command |= gsub("\\{gt_root\\}"; $g))}]' "$MANIFEST" 2>/dev/null)
printf '%s' "$DEFS" | jq -e 'type == "array" and any(.[]; .event == "SessionStart")' >/dev/null 2>&1 || { echo "FATAL: $MANIFEST não define common.hooks_extra_defs[\"pytest-shim\"].hooks.SessionStart[0]" >&2; exit 1; }
printf '%s' "$DEFS" | jq -e --arg mk "$MARKER" 'all(.[]; ((.matcher // "") != "") and ((.hook.command // "") | contains($mk)))' >/dev/null 2>&1 \
  || { echo "FATAL: algum hook do manifesto não traz matcher, ou o comando não carrega o marcador '$MARKER'" >&2; exit 1; }
CMD=$(printf '%s' "$DEFS" | jq -r '[.[] | select(.event == "SessionStart")][0].hook.command // empty')
SHIM_DIR=$(printf '%s' "$CMD" | sed -n "s/.*D='\\([^']*\\)'.*/\\1/p")
[ -n "$SHIM_DIR" ] || { echo "FATAL: não achei o D='...' no comando do manifesto" >&2; exit 1; }

CHECK=0; TARGETS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGETS+=("$a") ;;
  esac
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  shopt -s nullglob
  for f in "$RIGS_ROOT"/*/crew/.claude/settings.json "$RIGS_ROOT"/*/crew/*/.claude/settings.json; do TARGETS+=("$f"); done
  shopt -u nullglob
fi
[ "${#TARGETS[@]}" -gt 0 ] || { echo "FATAL: nenhum settings.json de crew em $RIGS_ROOT" >&2; exit 1; }

# O estado desejado, numa definição jq só, compartilhada por ativar e --check para não divergirem.
JQ_APPLY='
  def ours: ((.command // "") | contains($marker));
  def apply($ev; $m; $hook):
    (.hooks //= {}) | (.hooks[$ev] //= []) |
    ([.hooks[$ev] | to_entries[] | select(.value.matcher == $m) | .key][0]) as $first |
    .hooks[$ev] |= [to_entries[]
        | .key as $i | .value as $e
        | if $i == $first then
            ((($e.hooks // []) | map(ours)) | index(true)) as $pos
            | (if $pos == null then (($e.hooks // []) + [$hook])
               else ($e.hooks | to_entries
                     | map(select((.value | ours | not) or (.key == $pos)))
                     | map(if (.value | ours) then $hook else .value end))
               end) as $hs
            | ($e | .hooks = $hs)
          else
            ((($e.hooks // []) | map(select(ours))) | length) as $n
            | if $n == 0 then $e
              else (($e.hooks | map(select(ours | not))) as $keep
                    | if ($keep | length) == 0 then empty else ($e | .hooks = $keep) end)
              end
          end] |
    (if $first == null then (.hooks[$ev] += [{matcher: $m, hooks: [$hook]}]) else . end);
  reduce $defs[] as $d (.; apply($d.event; $d.matcher; $d.hook))'

# o hook SessionStart testa `[ -x python3 ]` e o PreToolUse também `[ -f ../venv-rewrite-hook.py ]`: os dois têm de existir para os hooks valerem alguma coisa
shim_present() { [ -x "$SHIM_DIR/python3" ] && [ -f "$SHIM_DIR/../venv-rewrite-hook.py" ]; }
INERT_NOTE="hooks registrados, mas $SHIM_DIR/python3 ou $SHIM_DIR/../venv-rewrite-hook.py não existe — os hooks são um no-op até existirem"

STATUS=0
for SETTINGS in "${TARGETS[@]}"; do
  if [ ! -f "$SETTINGS" ]; then echo "FATAL: settings.json não achado em $SETTINGS" >&2; STATUS=1; continue; fi
  TMP="$(mktemp "${TMPDIR:-/tmp}/pytest-shim-activate.XXXXXX")" || { STATUS=1; continue; }
  if ! jq --argjson defs "$DEFS" --arg marker "$MARKER" "$JQ_APPLY" "$SETTINGS" > "$TMP" 2>/dev/null; then
    echo "FATAL: jq falhou em $SETTINGS (JSON inválido, não é objeto, ou hooks.<evento> não é lista) — pulado, os outros alvos seguem" >&2
    rm -f "$TMP"; STATUS=1; continue
  fi
  # nunca sobrescrever um settings de verdade com algo que o jq não deveria ter produzido
  if ! jq -e 'type == "object"' "$TMP" >/dev/null 2>&1; then
    echo "FATAL: jq produziu JSON inválido para $SETTINGS — pulado, não sobrescrevo" >&2
    rm -f "$TMP"; STATUS=1; continue
  fi
  # "já ativo" se decide pelo estado SEMÂNTICO (jq -S), não pelos bytes: formatação diferente não reescreve (nem faz backup) a cada execução
  if [ "$(jq -S . "$SETTINGS" 2>/dev/null)" = "$(jq -S . "$TMP")" ]; then
    if shim_present; then echo "ACTIVE: $SETTINGS"; else echo "INERT: $SETTINGS ($INERT_NOTE)"; [ "$CHECK" -eq 1 ] && STATUS=1; fi
    rm -f "$TMP"; continue
  fi
  if [ "$CHECK" -eq 1 ]; then echo "NOT-ACTIVE: $SETTINGS"; rm -f "$TMP"; STATUS=1; continue; fi
  # Backup PRIMEIRO, e backup que falha é "não posso continuar": sobrescrever um settings vivo sem conseguir guardar o anterior é escrita destrutiva no "não sei".
  BAK="${SETTINGS}.bak.$(date +%s)"
  if ! cp -p "$SETTINGS" "$BAK" 2>/dev/null; then echo "FATAL: não consegui fazer backup de $SETTINGS — NÃO modificado" >&2; rm -f "$TMP"; STATUS=1; continue; fi
  # escreve por uma cópia do ORIGINAL (cp -p mantém modo e dono) e renomeia por cima, atômico
  NEW="${SETTINGS}.new.$$"
  if cp -p "$SETTINGS" "$NEW" 2>/dev/null && cat "$TMP" > "$NEW" 2>/dev/null && mv "$NEW" "$SETTINGS"; then
    if shim_present; then echo "Registered pytest-shim hooks in $SETTINGS"; else echo "Registered pytest-shim hooks in $SETTINGS — INERT: $SHIM_DIR/python3 ou venv-rewrite-hook.py não existe ainda, os hooks são um no-op até existirem"; fi
  else
    echo "FATAL: não consegui escrever $SETTINGS (original intacto; backup em $BAK)" >&2; rm -f "$NEW"; STATUS=1
  fi
  rm -f "$TMP"
done
exit "$STATUS"
