#!/usr/bin/env bash
# wa-node-classify.selftest.sh — hermético: o filtro e o rsync são os REAIS (o filtro é a fronteira de dados do nó), a lista mac-only e os rsync de falha são stubs numa pasta temporária. (ga-2hd02v.1.10)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: veredito node (prova no texto / etiqueta) · mini (etiqueta node:mini, epic, caminho que o filtro segura, teste só-no-Mac, telefone/CPF no texto, palavras de banco/credencial/host Mac)
#   · palavras informativas NÃO bloqueiam · duras vencem node:ok · unknown (sem prova, JSON ilegível, campo de tipo estranho, texto/entrada grande, filtro/mac-only ausente, rsync que falha/não
#   responde/lista tudo, canário errado, exceção inesperada) · caminho fora do formato não toca o disco · códigos de saída 0/10/11/2 · as regexes de telefone/CPF são as do hetzner-pii-scan.py.
# CONTROLE NEGATIVO: cada mutante abaixo troca UMA linha do classificador numa cópia e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/wa-node-classify.selftest.sh   (macOS /bin/bash 3.2 e Linux). Pesado o bastante para ir ao nó: scripts/mbp-run.sh --repo hq scripts/wa-node-classify.selftest.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLS_REAL="$HERE/wa-node-classify.py"
PII="$HERE/hetzner-pii-scan.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-cls.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
PY=${WA_NODE_SELFTEST_PY:-python3}

CLS="$CLS_REAL"; OUT=""; RC=0
run() { OUT=$(printf '%s' "$1" | "$PY" -I "$CLS" 2>/dev/null); RC=$?; }
# check <json> <rc> <regex da saída> -> 0 se o rc é o esperado e a saída casa; sem imprimir (os mutantes usam o mesmo)
check() { run "$1"; [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -q -E -e "$3"; }
expect() { # expect <rótulo> <json> <rc> <regex>
  if check "$2" "$3" "$4"; then ok "$1"; else bad "$1 (rc=$RC, esperado $3; saída: $(printf '%s' "$OUT" | cut -c1-230))"; fi
}
labels() { printf '%s' "${1%\}},\"labels\":$2}"; }
field() { printf '%s' "${1%\}},\"$2\":$3}"; }

GOOD='{"id":"wa-t1","title":"parse_bar devolve None para entrada vazia","description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}'
NOPROOF='{"id":"wa-t2","title":"melhorar mensagem de erro","description":"A mensagem de erro do importador esta confusa."}'
WITHDB='{"id":"wa-t3","title":"lê o banco","description":"scripts/foo.py lê queue.db; teste em tests/test_foo.py"}'
DESC() { printf '{"id":"wa-t9","title":"t","description":"%s"}' "$1"; }

# ---- node
expect "node: código + teste citados, nada que bloqueie" "$GOOD" 0 '"verdict": "node", "basis": "text".*prova-no-texto:1-teste\(s\)\+1-codigo'
expect "node: etiqueta node:ok dispensa a prova no texto" "$(labels "$NOPROOF" '["node:ok"]')" 0 '"verdict": "node", "basis": "label".*etiqueta-node:ok'
expect "node: id de pytest (::) e linha (:123) não atrapalham o caminho" "$(DESC 'tests/test_a.py::test_x quebra; ver lib/a.py:123')" 0 '"verdict": "node"'
expect "node: o caminho absoluto do repo é normalizado para o relativo" "$(DESC 'ver /Users/athos/gt/whatsapp_automation/lib/foo.py e tests/test_foo.py')" 0 '"paths": \["lib/foo.py", "tests/test_foo.py"\]'
expect "mini: outro caminho /Users/... (não o do repo) continua sendo host Mac" "$(DESC 'lib/x.py e tests/test_x.py; o diretorio /Users/athos/notas')" 10 'moles:host-mac'
expect "node: palavras do produto (lead, deploy, tela) só informam" "$(DESC 'lib/x.py trata lead no deploy da tela; tests/test_x.py')" 0 '"verdict": "node".*"info": \["producao", "tela-ao-vivo", "dado-de-lead"'
expect "node: telefone sintético (cauda repetida) não conta como dado" "$(DESC 'lib/x.py e tests/test_x.py usam +55 31 99999-9999 como exemplo')" 0 '"verdict": "node"'
# ---- mini
expect "mini: etiqueta node:mini vence node:ok" "$(labels "$GOOD" '["node:ok","node:mini"]')" 10 'etiqueta-node:mini'
expect "mini: epic" "$(field "$GOOD" issue_type '"epic"')" 10 '"reasons": \["epic"\]'
expect "mini: banco .db citado (o filtro segura)" "$WITHDB" 10 'caminho-fora-do-filtro:queue\.db'
expect "mini: pasta data/ citada (o filtro segura mesmo sendo .py)" "$(DESC 'lib/x.py usa data/helper.py; tests/test_x.py')" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "mini: credentials*.json citado" "$(DESC 'lib/x.py lê config/credentials_prod.json; tests/test_x.py')" 10 'caminho-fora-do-filtro:config/credentials_prod\.json'
expect "mini: doc .md fora do filtro" "$(DESC 'lib/x.py conforme docs/guia.md; tests/test_x.py')" 10 'caminho-fora-do-filtro:docs/guia\.md'
expect "mini: telefone real no texto (duro)" "$(DESC 'lib/x.py tests/test_x.py cliente (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "mini: CPF dentro da metadata (duro)" "$(field "$GOOD" metadata '{"k":"123.456.789-09"}')" 10 'dado-no-texto'
expect "mini: banco citado sem etiqueta (mole)" "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
expect "mini: credencial citada sem etiqueta" "$(DESC 'lib/x.py usa o token do pdpj; tests/test_x.py')" 10 'moles:credencial'
expect "mini: host Mac citado sem etiqueta" "$(DESC 'lib/x.py roda osascript; tests/test_x.py')" 10 'moles:host-mac'
expect "node:ok ignora a mole e DIZ que ignorou" "$(labels "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" '["node:ok"]')" 0 'moles-ignoradas:banco-de-dados'
expect "duro vence node:ok: caminho que o filtro segura" "$(labels "$WITHDB" '["node:ok"]')" 10 'caminho-fora-do-filtro:queue\.db'
expect "duro vence node:ok: telefone no texto" "$(labels "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" '["node:ok"]')" 10 'dado-no-texto'
expect "caminho com .. : fora do formato, não vai ao disco" "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato'
expect "caminho absoluto: fora do formato" "$(DESC 'lib/x.py e /etc/zz_evil.py com tests/test_x.py')" 10 'caminho-fora-do-formato'
# ---- unknown
expect "unknown: nada de código nem teste citado" "$NOPROOF" 11 'sem-prova-de-codigo-e-teste'
expect "unknown: só código, sem teste" "$(DESC 'ajustar lib/x.py')" 11 'sem-prova'
expect "unknown: JSON ilegível" 'isto nao e json' 11 'json-ilegivel'
expect "unknown: entrada vazia" '' 11 'entrada-vazia'
expect "unknown: lista com duas beads" "[$GOOD,$GOOD]" 11 'sem-id-ou-titulo'
expect "unknown: sem id" '{"title":"x","description":"lib/a.py tests/test_a.py"}' 11 'sem-id-ou-titulo'
expect "unknown: descrição que não é texto" "$(field "$GOOD" design '123')" 11 'campo-design-nao-e-texto'
expect "unknown: labels que é texto solto (não lista)" "$(labels "$GOOD" '"node:ok"')" 11 'labels-ilegiveis'
expect "unknown: labels com item que não é texto" "$(labels "$GOOD" '["a",1]')" 11 'labels-ilegiveis'
BIG=$("$PY" -I -c 'print("x"*300000)')
expect "unknown: texto da bead acima do teto (truncar esconderia palavra)" "$(printf '{"id":"wa-b","title":"t","description":"lib/a.py tests/test_a.py %s"}' "$BIG")" 11 'texto-grande'
expect "unknown: entrada acima de 1 MB" "$(printf '{"id":"wa-b","title":"t","description":"%s"}' "$("$PY" -I -c 'print("x"*1100000)')")" 11 'entrada-grande'
expect "unknown: exceção que ninguém previu (JSON aninhado demais) também é inerte" "$("$PY" -I -c 'print("["*200000)')" 11 'erro-inesperado'

# ---- filtro, mac-only e rsync: falha de leitura = unknown, nunca node
export WA_NODE_FILTER="$T/nao-existe.txt"
expect "unknown: filtro ausente" "$GOOD" 11 'filtro-ilegivel'
unset WA_NODE_FILTER
echo '+ *.py' > "$T/filtro-incompleto.txt"; export WA_NODE_FILTER="$T/filtro-incompleto.txt"
expect "unknown: filtro sem a negação final" "$GOOD" 11 'filtro-sem-negacao-final'
unset WA_NODE_FILTER
export WA_NODE_MAC_ONLY="$T/nao-existe.txt"
expect "unknown: lista mac-only ausente (com caminhos citados)" "$GOOD" 11 'mac-only-ilegivel'
expect "mac-only ausente não pesa quando a bead não cita caminho (node:ok)" "$(labels "$NOPROOF" '["node:ok"]')" 0 '"verdict": "node"'
unset WA_NODE_MAC_ONLY
printf '# só comentário\ntests/test_launchd_*.py\n' > "$T/macs.txt"; export WA_NODE_MAC_ONLY="$T/macs.txt"
expect "mini: teste que só roda no Mac" "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac:tests/test_launchd_plist\.py'
expect "node: lista mac-only que não casa não atrapalha" "$GOOD" 0 '"verdict": "node"'
unset WA_NODE_MAC_ONLY
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
stub rs-rc1 'exit 1'
stub rs-mudo 'exit 0'
stub rs-tudo 'cd "$6" && find . -type f | sed "s|^\./||"; exit 0'
stub rs-pendura 'sleep 6; exit 0'
export WA_NODE_RSYNC="$T/rs-rc1";    expect "unknown: rsync sai com erro" "$GOOD" 11 'rsync-rc-1'
export WA_NODE_RSYNC="$T/rs-mudo";   expect "unknown: rsync mudo (nenhum canário listado) — não vira 'nada sai'" "$GOOD" 11 'canario-errado'
export WA_NODE_RSYNC="$T/rs-tudo";   expect "unknown: rsync que lista TUDO (canário de segredo saiu)" "$GOOD" 11 'canario-errado'
export WA_NODE_RSYNC="$T/nao-existe-rsync"; expect "unknown: rsync inexistente" "$GOOD" 11 'rsync-sem-resposta'
export WA_NODE_RSYNC="$T/rs-pendura" WA_NODE_RSYNC_TIMEOUT=1; expect "unknown: rsync que não responde no prazo" "$GOOD" 11 'rsync-sem-resposta'
unset WA_NODE_RSYNC WA_NODE_RSYNC_TIMEOUT
export WA_NODE_RSYNC_TIMEOUT=abc; expect "prazo do rsync ilegível volta ao padrão (30) e não derruba" "$GOOD" 0 '"verdict": "node"'; unset WA_NODE_RSYNC_TIMEOUT

# ---- o classificador não deixa resíduo e só aceita stdin
mkdir -p "$T/tmpd"; run_tmp=$(printf '%s' "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" | TMPDIR="$T/tmpd" "$PY" -I "$CLS_REAL" >/dev/null 2>&1; ls -A "$T/tmpd" | wc -l | tr -d ' ')
[ "$run_tmp" = 0 ] && ok "sem resíduo no TMPDIR (a árvore temporária é apagada)" || bad "resíduo no TMPDIR: $run_tmp item(ns)"
"$PY" -I "$CLS_REAL" extra </dev/null >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] && ok "argumento a mais: rc 2 (uso)" || bad "argumento a mais: rc=$rc (esperado 2)"
# as regexes de telefone e CPF são as do hetzner-pii-scan.py (se uma mudar lá, o texto da bead passa a ser conferido por outra régua)
"$PY" -I - "$CLS_REAL" "$PII" <<'EOF' && ok "PH e CPF iguais aos do hetzner-pii-scan.py" || bad "PH/CPF divergem do hetzner-pii-scan.py"
import importlib.util, sys
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
a, b = load(sys.argv[1], "cls"), load(sys.argv[2], "pii")
sys.exit(0 if (a.PH.pattern == b.PH.pattern and a.CPF.pattern == b.CPF.pattern) else 1)
EOF

# ---- controle negativo: um mutante por linha; o caso designado tem de reprovar
mutant() { # mutant <nome> <trecho original> <trecho novo> <json> <rc> <regex>
  local name="$1" old="$2" new="$3" json="$4" rc="$5" rx="$6" M="$T/mut-$1.py"
  "$PY" -I - "$CLS_REAL" "$M" "$old" "$new" <<'EOF' || { bad "mutante $name: o trecho original não existe (o classificador mudou? atualize o mutante)"; return; }
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  CLS="$M"
  if check "$json" "$rc" "$rx"; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"; else ok "mutante $name morreu"; fi
  CLS="$CLS_REAL"
}
mutant sem-node-mini     '"node:mini" in labels'                       'False'                                  "$(labels "$GOOD" '["node:mini"]')" 10 'etiqueta-node:mini'
mutant sem-epic          'b.get("issue_type") == "epic"'               'False'                                  "$(field "$GOOD" issue_type '"epic"')" 10 '"epic"'
mutant sem-pii           'if has_pii(json.dumps'                       'if False and has_pii(json.dumps'        "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" 10 'dado-no-texto'
mutant pii-sem-cauda     'len(set(d[-8:])) > 3'                        'len(set(d[-8:])) >= 0'                  "$(DESC 'lib/x.py tests/test_x.py +55 31 99999-9999')" 0 '"verdict": "node"'
mutant filtro-ignorado   'if p not in sent:'                           'if False:'                              "$WITHDB" 10 'caminho-fora-do-filtro'
mutant mac-ignorado      'elif any(fnmatch.fnmatchcase(p, g) for g in globs):' 'elif False:'                    "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac'
mutant sem-canario       'if CANARY_OK not in sent or any(c in sent for c in CANARY_NO):' 'if False:'          "$GOOD" 11 'canario-errado'
mutant rc-ignorado       'if r.returncode != 0:'                       'if False:'                              "$GOOD" 11 'rsync-rc-1'
mutant sem-moles         'if soft and not override:'                   'if False:'                              "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
mutant label-ignorada    'override = "node:ok" in labels'              'override = False'                       "$(labels "$NOPROOF" '["node:ok"]')" 0 'label'
mutant prova-frouxa      'if tests and code:'                          'if tests or True:'                      "$NOPROOF" 11 'sem-prova'
mutant unreadable-node   'v, why, paths, tests, info = "unknown", ["nao-consegui:"' 'v, why, paths, tests, info = "node", ["nao-consegui:"' 'isto nao e json' 11 'json-ilegivel'
mutant caminho-solto     'any(s in ("", ".", "..") for s in segs)'     'False'                                  "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato'
mutant sem-teto-texto    'if len(text) > MAX_TEXT:'                    'if False:'                              "$(printf '{"id":"wa-b","title":"t","description":"lib/a.py tests/test_a.py %s"}' "$BIG")" 11 'texto-grande'
mutant labels-frouxas    'if not isinstance(lab, list) or not all(isinstance(x, str) for x in lab):' 'if False:' "$(labels "$GOOD" '"node:ok"')" 11 'labels-ilegiveis'
mutant abs-vira-mole     'norm(text.replace(REPO_ABS, ""))'            'norm(text)'                             "$(DESC 'ver /Users/athos/gt/whatsapp_automation/lib/foo.py e tests/test_foo.py')" 0 '"verdict": "node"'
mutant sem-catch-all    'except Exception as e:'                      'except ZeroDivisionError as e:'         "$("$PY" -I -c 'print("["*200000)')" 11 'erro-inesperado'

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
