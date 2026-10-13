#!/usr/bin/env bash
# pytest-shim-activate.selftest.sh — hermético: rigs, manifesto e atalho são cópias numa pasta descartável; nada toca os settings.json reais.
#
# Contents
#   Casos · Controles negativos
#
# CASOS: ativa numa crew que já tem hooks (gc prime --hook em SessionStart, dangerous-command em PreToolUse) sem tocar em nenhum deles · idempotente (2ª execução não reescreve
#   nem faz backup) · o hook escrito é BYTE A BYTE o que o overlay do wa-worker carrega (fonte única) · matcher próprio, nunca o do `gc prime --hook` · comando antigo é trocado NO LUGAR ·
#   cópia extra e entrada com o nosso hook noutro matcher saem sem tocar no que não é nosso · --check não escreve e diz ACTIVE / INERT / NOT-ACTIVE (rc 1 nos dois últimos) ·
#   alvos padrão = crews (as duas profundidades), NUNCA a raiz da cidade, o overlay-base, witness nem refinery · JSON ilegível ou hooks.SessionStart que não é lista não para os outros alvos ·
#   manifesto sem a definição / sem o marcador = FATAL sem escrever nada.
#   Controles negativos M1-M3: sem a idempotência semântica, sem a preservação dos hooks alheios e comando que diverge do manifesto — cada mutante tem de ser pego.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACT="$HERE/pytest-shim-activate.sh"
HQ="$(cd "$HERE/.." && pwd)"
MAN_SRC="$HQ/packs/town-deltas/assets/claude-overlays/pool-roles.json"
WA_OVERLAY="$HQ/packs/town-deltas/assets/claude-overlays/pool-wa-worker/.claude/settings.json"
command -v jq >/dev/null || { echo "FATAL: jq ausente"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pytest-shim-activate-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
ROOT="$T/gt"; mkdir -p "$ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin" "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays" "$ROOT/wa/crew/oracle/.claude" "$ROOT/wa/crew/.claude" "$ROOT/ps/crew/mila/.claude" "$ROOT/wa/witness/.claude" "$ROOT/wa/refinery/.claude"
cp "$MAN_SRC" "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json"
: > "$ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin/python3"; chmod +x "$ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin/python3"
export PYTEST_SHIM_RIGS_ROOT="$ROOT" PYTEST_SHIM_GT_ROOT="$ROOT"
CREW1="$ROOT/wa/crew/oracle/.claude/settings.json"; CREW2="$ROOT/ps/crew/mila/.claude/settings.json"; CREW3="$ROOT/wa/crew/.claude/settings.json"
WIT="$ROOT/wa/witness/.claude/settings.json"; REF="$ROOT/wa/refinery/.claude/settings.json"
CITYS="$ROOT/.gascity-gastown-hq/.claude/settings.json"; mkdir -p "$ROOT/.gascity-gastown-hq/.claude"
fails=0; n=0
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: esperado '$2', veio '$3'"; fails=$((fails+1)); fi; }
has()   { n=$((n+1)); if grep -q -E -e "$3" "$2" 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi; }
hasnt() { n=$((n+1)); if grep -q -E -e "$3" "$2" 2>/dev/null; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi; }
fresh() { # settings de crew realistas: já tem SessionStart (gc prime --hook, matcher vazio) e PreToolUse com dois hooks
  cat > "$1" <<'EOF'
{"permissions":{"deny":["Bash(sudo:*)"]},"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/Users/athos/.local/bin/gt prime --hook"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"dangerous-command-guard a"},{"type":"command","command":"dangerous-command-guard b"}]}]}}
EOF
}
for f in "$CREW1" "$CREW2" "$CREW3"; do fresh "$f"; done; fresh "$WIT"; fresh "$REF"; fresh "$CITYS"
WANT_CMD=$(jq -r '.hooks.SessionStart[] | select(.matcher == "^(startup|resume|clear|compact)$") | .hooks[0].command' "$WA_OVERLAY" | sed "s#/Users/athos/gt#$ROOT#")
ss() { jq -c '.hooks.SessionStart' "$1"; }
pre() { jq -c '.hooks.PreToolUse' "$1"; }

# 1 ativa nos alvos padrão (as duas profundidades de crew) e só neles
out=$("$ACT" 2>&1); rc=$?; expect "ativa: rc 0" 0 "$rc"
for f in "$CREW1" "$CREW2" "$CREW3"; do
  expect "$(basename "$(dirname "$(dirname "$f")")") ($f): hook nosso presente" 1 "$(jq '[.hooks.SessionStart[] | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$f")"
  expect "…o gc prime --hook continua intacto, na posição 0" '{"matcher":"","hooks":[{"type":"command","command":"/Users/athos/.local/bin/gt prime --hook"}]}' "$(jq -c '.hooks.SessionStart[0]' "$f")"
  expect "…os hooks do PreToolUse não foram tocados" '[{"matcher":"Bash","hooks":[{"type":"command","command":"dangerous-command-guard a"},{"type":"command","command":"dangerous-command-guard b"}]}]' "$(pre "$f")"
  expect "…permissions intactas" '["Bash(sudo:*)"]' "$(jq -c '.permissions.deny' "$f")"
done
for f in "$WIT" "$REF" "$CITYS"; do expect "alvo padrão NÃO inclui $(basename "$(dirname "$(dirname "$f")")")/…$(basename "$(dirname "$f")") (witness, refinery, raiz da cidade)" 0 "$(jq '[.hooks.SessionStart[]? | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$f")"; done
# 2 fonte única: o hook escrito é byte a byte o do overlay do wa-worker (com a raiz trocada)
expect "o comando escrito == o comando do overlay do wa-worker (fonte única)" "$WANT_CMD" "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$CREW1")"
expect "o matcher é próprio, não o do gc prime" '^(startup|resume|clear|compact)$' "$(jq -r '.hooks.SessionStart[1].matcher' "$CREW1")"
expect "o timeout vem do manifesto" 5 "$(jq '.hooks.SessionStart[1].hooks[0].timeout' "$CREW1")"
# 3 idempotente: 2ª execução não reescreve nem faz backup
before=$(ls "$ROOT"/wa/crew/oracle/.claude | wc -l | tr -d ' ')
out=$("$ACT" 2>&1); rc=$?; expect "2ª execução: rc 0" 0 "$rc"; expect "2ª execução: tudo ACTIVE" 3 "$(echo "$out" | grep -c '^ACTIVE')"
expect "2ª execução: nenhum backup novo" "$before" "$(ls "$ROOT"/wa/crew/oracle/.claude | wc -l | tr -d ' ')"
# 4 --check
out=$("$ACT" --check 2>&1); rc=$?; expect "--check com tudo ativo: rc 0" 0 "$rc"
fresh "$CREW2"; out=$("$ACT" --check 2>&1); rc=$?; expect "--check com uma crew sem o hook: rc 1" 1 "$rc"; echo "$out" | grep -q "^NOT-ACTIVE: $CREW2" && expect "--check diz NOT-ACTIVE na crew certa" 1 1 || expect "--check diz NOT-ACTIVE na crew certa" 1 0
expect "--check NÃO escreveu nada" 0 "$(jq '[.hooks.SessionStart[]? | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$CREW2")"
"$ACT" >/dev/null 2>&1
# 5 comando antigo é trocado NO LUGAR (posição preservada), cópia extra e o nosso hook noutro matcher saem
jq '(.hooks.SessionStart[] | select(.matcher == "^(startup|resume|clear|compact)$") | .hooks) = [{"type":"command","command":": pytest-shim; exit 0 # velho"},{"type":"command","command":"outro-hook-de-alguem"},{"type":"command","command":": pytest-shim; exit 0 # copia"}]
    | .hooks.SessionStart += [{"matcher":"startup","hooks":[{"type":"command","command":": pytest-shim; exit 0 # dobrado no matcher errado"},{"type":"command","command":"hook-que-fica"}]}]' "$CREW1" > "$T/c1" && cp "$T/c1" "$CREW1"
"$ACT" "$CREW1" >/dev/null 2>&1
expect "comando velho trocado pelo atual, no mesmo lugar (posição 0 da entrada dedicada)" "$WANT_CMD" "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$CREW1")"
expect "o hook alheio da entrada dedicada ficou, depois do nosso" "outro-hook-de-alguem" "$(jq -r '.hooks.SessionStart[1].hooks[1].command' "$CREW1")"
expect "a cópia extra sumiu (um hook nosso na entrada dedicada)" 1 "$(jq '[.hooks.SessionStart[1].hooks[] | select(.command | contains("pytest-shim"))] | length' "$CREW1")"
expect "o hook nosso dobrado em outro matcher saiu, o alheio ficou" '[{"type":"command","command":"hook-que-fica"}]' "$(jq -c '.hooks.SessionStart[2].hooks' "$CREW1")"
# 6 INERT: o atalho não existe na checkout (merge ainda não chegou)
mv "$ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin/python3" "$T/py3.away"
out=$("$ACT" --check 2>&1); rc=$?; expect "--check com o atalho ausente: rc 1" 1 "$rc"; expect "…diz INERT (registrado mas no-op) nas 3 crews ativadas" 3 "$(echo "$out" | grep -c "^INERT")"
mv "$T/py3.away" "$ROOT/.gascity-gastown-hq/scripts/pytest-shim/bin/python3"
# 7 alvo ruim não para os outros
printf '{ isto nao e json' > "$ROOT/wa/crew/.claude/settings.json"; fresh "$CREW2"
out=$("$ACT" 2>&1); rc=$?; expect "JSON ilegível: rc 1 (falhou um alvo)" 1 "$rc"; expect "…mas a crew boa foi ativada" 1 "$(jq '[.hooks.SessionStart[] | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$CREW2")"
expect "…e o arquivo ilegível ficou como estava" '{ isto nao e json' "$(cat "$ROOT/wa/crew/.claude/settings.json")"
fresh "$CREW3"; jq '.hooks.SessionStart = "nao e lista"' "$CREW3" > "$T/c3" && cp "$T/c3" "$CREW3"; fresh "$CREW2"
out=$("$ACT" 2>&1); rc=$?; expect "hooks.SessionStart que não é lista: rc 1, sem estourar" 1 "$rc"; expect "…a crew boa foi ativada mesmo assim" 1 "$(jq '[.hooks.SessionStart[] | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$CREW2")"
fresh "$CREW3"
# 8 manifesto sem a definição / sem o marcador: FATAL, nada escrito
cp "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json" "$T/man.ok"
jq 'del(.common.hooks_extra_defs)' "$T/man.ok" > "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json"; fresh "$CREW1"
out=$("$ACT" 2>&1); rc=$?; expect "manifesto sem a definição: rc 1" 1 "$rc"; expect "…nada escrito" 0 "$(jq '[.hooks.SessionStart[]? | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$CREW1")"
jq '.common.hooks_extra_defs["pytest-shim"].hooks.SessionStart[0].hooks[0].command = ": sem marcador; exit 0"' "$T/man.ok" > "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json"
out=$("$ACT" 2>&1); rc=$?; expect "comando do manifesto sem o marcador: rc 1" 1 "$rc"; expect "…nada escrito" 0 "$(jq '[.hooks.SessionStart[]? | select(.hooks[]? | .command | contains("pytest-shim"))] | length' "$CREW1")"
cp "$T/man.ok" "$ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool-roles.json"

# =============================== M. controles negativos ===============================
mutant() { # <nome> <sed-expr> → cópia do script alterada
  sed -e "$2" "$ACT" > "$T/mut-$1.sh"; chmod +x "$T/mut-$1.sh"
  cmp -s "$ACT" "$T/mut-$1.sh" && { echo "FAIL mutante $1: o sed não mudou nada (o controle não controla)"; fails=$((fails+1)); n=$((n+1)); return 1; }; return 0; }
# M1 sem a comparação semântica: sempre "mudou" → a 2ª execução reescreveria e faria backup
mutant m1 's#^  if \[ "\$(jq -S . "\$SETTINGS" 2>/dev/null)" = "\$(jq -S . "\$TMP")" \]; then#  if false; then#' && {
  fresh "$CREW1"; "$T/mut-m1.sh" "$CREW1" >/dev/null 2>&1; b1=$(ls "$ROOT"/wa/crew/oracle/.claude | wc -l | tr -d ' '); "$T/mut-m1.sh" "$CREW1" >/dev/null 2>&1; b2=$(ls "$ROOT"/wa/crew/oracle/.claude | wc -l | tr -d ' ')
  n=$((n+1)); if [ "$b1" != "$b2" ] || { sleep 1; "$T/mut-m1.sh" "$CREW1" >/dev/null 2>&1; [ "$(ls "$ROOT"/wa/crew/oracle/.claude | wc -l | tr -d ' ')" != "$b2" ]; }; then echo "ok   M1 sem a idempotência semântica a 2ª execução reescreve (o caso 3 reprova o mutante)"; else echo "FAIL M1: o mutante NÃO foi pego"; fails=$((fails+1)); fi; }
# M2 sem preservar hooks alheios na entrada dedicada: a entrada passa a ter só o nosso
mutant m2 's#then (($e.hooks // \[\]) + \[$hook\])#then [$hook]#' && {
  fresh "$CREW1"; jq '.hooks.SessionStart += [{"matcher":"^(startup|resume|clear|compact)$","hooks":[{"type":"command","command":"hook-alheio"}]}]' "$CREW1" > "$T/c1" && cp "$T/c1" "$CREW1"
  "$T/mut-m2.sh" "$CREW1" >/dev/null 2>&1; c=$(jq '[.hooks.SessionStart[].hooks[] | select(.command == "hook-alheio")] | length' "$CREW1")
  n=$((n+1)); if [ "$c" = 0 ]; then echo "ok   M2 sem a preservação, o hook alheio na entrada dedicada some (o caso 5 reprova o mutante)"; else echo "FAIL M2: o mutante NÃO foi pego (hook alheio ainda lá: $c)"; fails=$((fails+1)); fi; }
# M3 comando que diverge do manifesto: o mutante escreve outro texto
mutant m3 's#--argjson hook "\$HOOK"#--argjson hook "{\\"type\\":\\"command\\",\\"command\\":\\": pytest-shim; exit 0\\",\\"timeout\\":5}"#' && {
  fresh "$CREW1"; "$T/mut-m3.sh" "$CREW1" >/dev/null 2>&1; got=$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$CREW1")
  n=$((n+1)); if [ "$got" != "$WANT_CMD" ]; then echo "ok   M3 comando divergente do manifesto é visível (o caso 2 reprova o mutante)"; else echo "FAIL M3: o mutante NÃO foi pego"; fails=$((fails+1)); fi; }

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
