#!/usr/bin/env bash
# install.sh — materializa a skill aeronave-e-voos no mini. Idempotente.
#
# ⚠️ INSTALA EM UM LUGAR SÓ, de propósito: ~/.claude/skills (escopo user-global),
# exatamente como o install.sh do browser-control. A distribuição para os provider
# dirs de cada agente/rig (.claude/.codex/.gemini/skills de cada clone) é feita
# pelo FRAMEWORK a partir da fonte da cidade — não por este script.
#
# Uma versão anterior deste arquivo varria `find ~/gt -type d -name skills` e
# copiava em TODOS os resultados: 404 destinos, escrevendo dentro do espaço de
# outros agentes e de árvores que nem são de skill (~/gt/docs/skills). Foi
# revertido na mesma hora. Não reintroduza a varredura.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="aeronave-e-voos"
DST="$HOME/.claude/skills/$NAME"

mkdir -p "$DST"
cp -f "$SRC_DIR/SKILL.md" "$DST/SKILL.md"

echo "OK — skill $NAME instalada em $DST"
echo "Fonte canônica (edite AQUI): $SRC_DIR/SKILL.md"
