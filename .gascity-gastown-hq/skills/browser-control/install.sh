#!/usr/bin/env bash
# install.sh — materializa a skill browser-control no mini.
# Idempotente. Faz três coisas:
#   1. Garante que playwright-core + puppeteer-core resolvem para scripts de
#      agente (store compartilhado ~/.local/share/cdp-drive/node_modules).
#   2. Instala a skill em ~/.claude/skills/browser-control/ (escopo user-global,
#      igual à federated-site-login), copiando deste diretório-fonte versionado.
#   3. Garante o @playwright/mcp numa versão FIXA em ~/.local/share/playwright-mcp
#      (ga-g7zyxc3). É o que o servidor MCP `playwright-cdp` executa, direto com
#      node: sem `npx`, sem consulta ao registry e sem o processo `npm exec` na
#      frente. Registrar o servidor no Claude é um passo à parte (comando no
#      SKILL.md, "Versão fixa"): esta instalação não mexe no ~/.claude.json.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="$HOME/.local/share/cdp-drive"
SKILL_DST="$HOME/.claude/skills/browser-control"
PW_MCP_VERSION="0.0.83"   # trocar a versão = editar AQUI e no SKILL.md, de propósito
PW_MCP_DIR="$HOME/.local/share/playwright-mcp"

echo "==> 1/3 garantindo módulos CDP em $STORE/node_modules"
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

echo "==> 2/3 instalando skill em $SKILL_DST"
mkdir -p "$SKILL_DST"
cp -f "$SRC_DIR/SKILL.md" "$SKILL_DST/SKILL.md"

echo "==> 3/3 garantindo @playwright/mcp@$PW_MCP_VERSION (fixo) em $PW_MCP_DIR"
mkdir -p "$PW_MCP_DIR"
[ -f "$PW_MCP_DIR/package.json" ] || printf '{"name":"playwright-mcp-pinned","private":true}\n' > "$PW_MCP_DIR/package.json"
# versão ilegível (pacote ausente ou quebrado) = "não tenho": instala; nunca conta como "já está na versão certa"
have="$(node -p 'require(process.argv[1]).version' "$PW_MCP_DIR/node_modules/@playwright/mcp/package.json" 2>/dev/null || true)"
if [ "$have" = "$PW_MCP_VERSION" ]; then
  echo "    já na $have (nada a fazer)"
else
  echo "    presente: '${have:-nenhuma}' -> instalando $PW_MCP_VERSION (--ignore-scripts, sem baixar browser)"
  (cd "$PW_MCP_DIR" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
     npm install --no-audit --no-fund --ignore-scripts --save-exact "@playwright/mcp@$PW_MCP_VERSION")
fi

echo "==> verificando resolução"
NODE_PATH="$STORE/node_modules" node -e '
  const p=require("puppeteer-core/package.json").version;
  const w=require("playwright-core/package.json").version;
  console.log("    puppeteer-core "+p+"  |  playwright-core "+w);
'
node "$PW_MCP_DIR/node_modules/@playwright/mcp/cli.js" --version | sed 's/^/    @playwright\/mcp /'
echo "OK — skill browser-control instalada."
