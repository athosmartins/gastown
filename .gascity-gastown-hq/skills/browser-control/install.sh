#!/usr/bin/env bash
# install.sh — materializa a skill browser-control no mini.
# Idempotente. Faz duas coisas:
#   1. Garante que playwright-core + puppeteer-core resolvem para scripts de
#      agente (store compartilhado ~/.local/share/cdp-drive/node_modules).
#   2. Instala a skill em ~/.claude/skills/browser-control/ (escopo user-global,
#      igual à federated-site-login), copiando deste diretório-fonte versionado.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="$HOME/.local/share/cdp-drive"
SKILL_DST="$HOME/.claude/skills/browser-control"

echo "==> 1/2 garantindo módulos CDP em $STORE/node_modules"
mkdir -p "$STORE"
[ -f "$STORE/package.json" ] || (cd "$STORE" && npm init -y >/dev/null 2>&1)
need=()
node -e 'require.resolve("puppeteer-core",{paths:["'"$STORE"'/node_modules"]})' 2>/dev/null || need+=("puppeteer-core")
node -e 'require.resolve("playwright-core",{paths:["'"$STORE"'/node_modules"]})' 2>/dev/null || need+=("playwright-core")
if [ "${#need[@]}" -gt 0 ]; then
  echo "    instalando: ${need[*]}"
  (cd "$STORE" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 PUPPETEER_SKIP_DOWNLOAD=1 \
     npm install --no-audit --no-fund "${need[@]}")
else
  echo "    já presentes (nada a fazer)"
fi

echo "==> 2/2 instalando skill em $SKILL_DST"
mkdir -p "$SKILL_DST"
cp -f "$SRC_DIR/SKILL.md" "$SKILL_DST/SKILL.md"

echo "==> verificando resolução"
NODE_PATH="$STORE/node_modules" node -e '
  const p=require("puppeteer-core/package.json").version;
  const w=require("playwright-core/package.json").version;
  console.log("    puppeteer-core "+p+"  |  playwright-core "+w);
'
echo "OK — skill browser-control instalada."
