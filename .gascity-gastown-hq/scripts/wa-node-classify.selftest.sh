#!/usr/bin/env bash
# wa-node-classify.selftest.sh — hermético: o filtro e o rsync são os REAIS (o filtro é a fronteira de dados do nó), a lista mac-only e os rsync de falha são stubs numa pasta temporária. (ga-2hd02v.1.10)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: veredito node (prova no texto / etiqueta) · mini (etiqueta node:mini, epic, caminho que o filtro segura, teste só-no-Mac, telefone/CPF no texto, palavras de banco/credencial/host Mac)
#   · palavras informativas NÃO bloqueiam · duras vencem node:ok · unknown (sem prova, JSON ilegível, campo de tipo estranho, texto/entrada grande, filtro (ausente ou furado)/mac-only (ausente
#   ou sem glob) ausente, rsync que falha/sai com rc 23/não responde/lista tudo, canário errado, exceção inesperada) · caminho fora do formato (.., absoluto, ~/, $VAR/) não toca o disco ·
#   teto de 40 caminhos · códigos de saída 0/10/11/2 · as regexes de telefone/CPF são as do hetzner-pii-scan.py.
#   · TESTE DERIVADO (ga-2hd02v.3.15, regra 6): um repo git de mentira faz o papel do repo do WA (origin/main; o working tree e o HEAD à frente não valem); node/derivado só com código rastreado + teste de nome do módulo
#   que CITA o módulo (palavra inteira) + teste que o nó tem (rsync, mac-only, espelho); módulo mais longo, nome curto/genérico, prefixo sem `_`, extensão fora de py/js/cjs/mjs e código que não existe em origin/main NÃO ganham teste;
#   lead/envio no texto mandam ao mini (freio-derivado); repo/ref/git/grep/espelho que falham dão unknown COM a nota e vazio dá unknown SEM nota (três estados).
# CONTROLE NEGATIVO: cada mutante abaixo troca UMA linha do classificador numa cópia e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria. Um mutante só vale se o
#   ORIGINAL passa o mesmo caso no mesmo ambiente e se ele não morre por causa do ambiente (ver as 3 regras acima de mk_mutant); caso e mutante de rsync usam stubs que só o mutante separa do original.
# COMO RODAR: bash scripts/wa-node-classify.selftest.sh   (macOS /bin/bash 3.2 e Linux). Pesado o bastante para ir ao nó: scripts/mbp-run.sh --repo hq scripts/wa-node-classify.selftest.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLS_REAL="$HERE/wa-node-classify.py"
PII="$HERE/hetzner-pii-scan.py"
REAL_FILTER="$HERE/hetzner-rsync-filter.wa.txt"; REAL_MAC="$HERE/hetzner-mac-only.txt"   # um classificador que mora fora de scripts/ (os mutantes) acha o filtro por env, não por HERE
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-cls.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
PY=${WA_NODE_SELFTEST_PY:-python3}
export WA_NODE_MIRROR="$T/espelho-ausente"   # os casos antigos valem SEM espelho (cai no filtro do rsync); o espelho entra só nos casos da seção "espelho git", com um stub
export WA_NODE_REPO="$T/wa-repo-ausente"     # idem o repo do WA (regra 6): os casos antigos nunca olham o repo de verdade desta máquina; a seção "teste derivado" monta um de mentira
export WA_NODE_CACHE="$T/cache"            # cache das irmãs (regra 7): nunca o do .gc/ de verdade; os casos que precisam de cache limpo/proibido trocam por env

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
expect "mini: doc .md fora do filtro, SEM espelho legível (cai no filtro do rsync e diz por quê)" "$(DESC 'lib/x.py conforme docs/guia.md; tests/test_x.py')" 10 'caminho-fora-do-filtro:docs/guia\.md.*espelho-ilegivel:espelho-sem-resposta'
expect "mini: telefone real no texto (duro)" "$(DESC 'lib/x.py tests/test_x.py cliente (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "mini: CPF dentro da metadata (duro)" "$(field "$GOOD" metadata '{"k":"123.456.789-09"}')" 10 'dado-no-texto'
expect "mini: banco citado sem etiqueta (mole)" "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
expect "mini: credencial citada sem etiqueta" "$(DESC 'lib/x.py usa o token do pdpj; tests/test_x.py')" 10 'moles:credencial'
expect "mini: host Mac citado sem etiqueta" "$(DESC 'lib/x.py roda osascript; tests/test_x.py')" 10 'moles:host-mac'
expect "node:ok ignora a mole e DIZ que ignorou" "$(labels "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" '["node:ok"]')" 0 'moles-ignoradas:banco-de-dados'
expect "duro vence node:ok: caminho que o filtro segura" "$(labels "$WITHDB" '["node:ok"]')" 10 'caminho-fora-do-filtro:queue\.db'
expect "duro vence node:ok: telefone no texto" "$(labels "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" '["node:ok"]')" 10 'dado-no-texto'
expect "caminho com .. : fora do formato, não entra na lista que vai ao disco" "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "caminho absoluto: fora do formato" "$(DESC 'lib/x.py e /etc/zz_evil.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "caminho com letra não-ASCII: fora do formato (SAFE_SEG)" "$(DESC 'lib/x.py tests/test_x.py e lib/ação.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "~/caminho: host Mac, fora do formato" "$(DESC 'lib/x.py tests/test_x.py e ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
expect '$HOME/caminho: host Mac, fora do formato' "$(DESC 'lib/x.py tests/test_x.py e $HOME/dados/y.csv')" 10 'caminho-fora-do-formato'
expect "extensão em MAIÚSCULA também passa pelo filtro" "$(DESC 'lib/x.py tests/test_x.py e DATA/Leads.CSV')" 10 'caminho-fora-do-filtro:DATA/Leads\.CSV'
expect ".sqlite3 citado (o filtro segura)" "$(DESC 'lib/x.py tests/test_x.py e data/x.sqlite3')" 10 'caminho-fora-do-filtro:data/x\.sqlite3'
P39=$(for i in $(seq 1 39); do printf 'lib/m%d.py ' "$i"; done)
expect "node: exatamente 40 caminhos (39 de código + 1 teste) ainda valem" "$(DESC "${P39}tests/test_x.py")" 0 '"verdict": "node"'
expect "mini: o 41º caminho estoura o teto" "$(DESC "${P39}lib/m40.py tests/test_x.py")" 10 'caminhos-demais'
# ---- unknown
expect "unknown: lib/x.py.bak não vira lib/x.py (a prova de 'código' seria de um arquivo que ninguém citou)" "$(DESC 'lib/x.py.bak e tests/test_x.py')" 11 '"paths": \["tests/test_x\.py"\]'
expect "node: ponto final de frase não atrapalha o caminho" "$(DESC 'Ajustar lib/x.py. Depois rodar tests/test_x.py.')" 0 '"paths": \["lib/x.py", "tests/test_x.py"\]'
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
printf '# so comentario, nenhum glob\n' > "$T/macs-vazio.txt"; export WA_NODE_MAC_ONLY="$T/macs-vazio.txt"
expect "unknown: lista mac-only SEM nenhum glob (truncada?) não vira 'nada é só-Mac'" "$GOOD" 11 'mac-only-vazio'
unset WA_NODE_MAC_ONLY
printf '# só comentário\ntests/test_launchd_*.py\n' > "$T/macs.txt"; export WA_NODE_MAC_ONLY="$T/macs.txt"
expect "mini: teste que só roda no Mac" "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac:tests/test_launchd_plist\.py'
expect "node: lista mac-only que não casa não atrapalha" "$GOOD" 0 '"verdict": "node"'
unset WA_NODE_MAC_ONLY
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
printf '+ */\n+ *.py\n- *.pyc\n' > "$T/filtro-furado.txt"   # tem "- *" como TEXTO (passa a checagem de substring) mas não nega o resto: só o canário de segredo pega
export WA_NODE_FILTER="$T/filtro-furado.txt"
expect "unknown: filtro furado ('- *.pyc' não é a negação final) deixa sair canário de segredo" "$GOOD" 11 'canario-errado'
unset WA_NODE_FILTER
# argv do rsync no classificador: $1=-a $2=-n $3=--out-format $4=--filter $5=<origem>/ $6=<destino>/ (o destino é SEMPRE vazio: quem "lista tudo" lista a origem, $5)
stub rs-rc1 'exit 1'
stub rs-mudo 'exit 0'
stub rs-tudo 'cd "$5" && find . -type f | sed "s|^\./||"; exit 0'
stub rs-parcial 'printf "%s\n" lib/foo_parser.py tests/test_foo_parser.py tests/test_zz_wa_node_canary.py; exit 23'   # saída "boa" (canário de código + os arquivos do GOOD) com rc 23 (transferência parcial)
stub rs-pendura 'sleep 6; exit 0'
export WA_NODE_RSYNC="$T/rs-rc1";    expect "unknown: rsync sai com erro" "$GOOD" 11 'rsync-rc-1'
export WA_NODE_RSYNC="$T/rs-parcial"; expect "unknown: rsync que lista o esperado mas sai com rc 23 — saída boa não salva rc != 0" "$GOOD" 11 'rsync-rc-23'
export WA_NODE_RSYNC="$T/rs-mudo";   expect "unknown: rsync mudo (nenhum canário listado) — não vira 'nada sai'" "$GOOD" 11 'canario-errado'
export WA_NODE_RSYNC="$T/rs-tudo";   expect "unknown: rsync que lista TUDO (canário de segredo saiu)" "$GOOD" 11 'canario-errado'
export WA_NODE_RSYNC="$T/nao-existe-rsync"; expect "unknown: rsync inexistente" "$GOOD" 11 'rsync-sem-resposta'
export WA_NODE_RSYNC="$T/rs-pendura" WA_NODE_RSYNC_TIMEOUT=1; expect "unknown: rsync que não responde no prazo" "$GOOD" 11 'rsync-sem-resposta'
unset WA_NODE_RSYNC WA_NODE_RSYNC_TIMEOUT
export WA_NODE_RSYNC_TIMEOUT=abc; expect "prazo do rsync ilegível volta ao padrão (30) e não derruba" "$GOOD" 0 '"verdict": "node"'; unset WA_NODE_RSYNC_TIMEOUT


# ---- espelho git (ga-2hd02v.3): .md que o rsync não lista mas o espelho entrega (docs/, DESIGN.md...) deixa de ser "fora do filtro"; só com o espelho legível E a varredura de conteúdo, senão volta ao filtro do rsync
# spec = Seção 1 do filtro real + pastas de dado (o `sparse` sem rig) + um caminho que a varredura de CONTEÚDO sinalizou (docs/sinalizado.md); o espelho de verdade serve o mesmo formato em `spec-out <rig>`
HETZNER_MIRROR_FILTER="$REAL_FILTER" bash "$HERE/hetzner-mirror.sh" sparse > "$T/spec.txt" 2>/dev/null; echo '!/docs/sinalizado.md' >> "$T/spec.txt"
echo '!/tests/test_flag_mod.py' >> "$T/spec.txt"   # um TESTE que a varredura de conteúdo sinalizou (a regra 6 não pode contá-lo como "teste que o nó tem")
[ "$(wc -l < "$T/spec.txt")" -gt 25 ] && ok "spec de teste gerado pelo hetzner-mirror.sh real (>25 linhas)" || bad "spec de teste não gerado: o hetzner-mirror.sh sparse falhou"
stub mirror-ok '[ "$1" = spec-out ] && [ "$2" = whatsapp_automation ] || exit 2; cat "'"$T"'/spec.txt"'
printf '#!/bin/sh\ncat "%s/spec.txt"\nexit 75\n' "$T" > "$T/mirror-75"; chmod +x "$T/mirror-75"   # o espelho que sai com rc 75 mesmo imprimindo um spec bom
stub mirror-vazio 'exit 0'
stub mirror-pendura 'sleep 6; cat "'"$T"'/spec.txt"'
{ echo '!zz-primeira'; sed '1d' "$T/spec.txt"; } > "$T/spec-sem-raiz.txt"; stub mirror-sem-raiz 'cat "'"$T"'/spec-sem-raiz.txt"'
{ echo '/*'; echo '!*.csv'; echo '!*.db'; echo '!*.parquet'; echo '!.env'; echo '!*.duckdb*'; echo '!data/'; } > "$T/spec-curto.txt"; stub mirror-curto 'cat "'"$T"'/spec-curto.txt"'
grep -vxF '!*.parquet' "$T/spec.txt" > "$T/spec-sem-parquet.txt"; stub mirror-sem-parquet 'cat "'"$T"'/spec-sem-parquet.txt"'
{ cat "$T/spec.txt"; echo 'docs/sem-bang.md'; } > "$T/spec-torta.txt"; stub mirror-torta 'cat "'"$T"'/spec-torta.txt"'
{ cat "$T/spec.txt"; echo '!*.md'; } > "$T/spec-nega-md.txt"; stub mirror-nega-md 'cat "'"$T"'/spec-nega-md.txt"'
stub git-mudo '[ "$1" = init ] && exit 0; exit 1'   # init ok, check-ignore sem nada negado (rc 1): nem o canário de dado é negado
printf '#!/bin/sh\n[ "$1" = init ] && exit 0\nexit 128\n' > "$T/git-quebrado"; chmod +x "$T/git-quebrado"   # init ok, check-ignore quebra (rc 128)
DOCS='lib/x.py e tests/test_x.py conforme '
export WA_NODE_MIRROR="$T/mirror-ok"
expect "node: .md fora da lista do rsync, mas o espelho entrega (docs/) — e DIZ que foi pelo espelho" "$(DESC "${DOCS}docs/runbooks/guia.md")" 0 '"verdict": "node".*"info": \[.*"via-espelho:docs/runbooks/guia\.md"'
expect "node: DESIGN.md na raiz (o espelho entrega)" "$(DESC "${DOCS}DESIGN.md")" 0 '"verdict": "node".*via-espelho:DESIGN\.md'
expect "node: .md maiúsculo (README.MD) também" "$(DESC "${DOCS}docs/LEIAME.MD")" 0 'via-espelho:docs/LEIAME\.MD'
expect "mini: .md que a varredura de CONTEÚDO sinalizou (espelho nega) segue fora" "$(DESC "${DOCS}docs/sinalizado.md")" 10 'caminho-fora-do-filtro:docs/sinalizado\.md'
expect "mini: .md em pasta que o rsync NUNCA deixa sair (shared/), mesmo o espelho não negando" "$(DESC "${DOCS}shared/notas.md")" 10 'caminho-fora-do-filtro:shared/notas\.md'
expect "mini: .md dentro de logs/ (pasta de dado) segue fora" "$(DESC "${DOCS}logs/relatorio.md")" 10 'caminho-fora-do-filtro:logs/relatorio\.md'
expect "mini: .json neutro em docs/ NÃO ganha o espelho (só texto .md)" "$(DESC "${DOCS}docs/auto_response/ab_results/x.json")" 10 'caminho-fora-do-filtro:docs/auto_response/ab_results/x\.json'
expect "mini: .txt neutro em docs/ também não" "$(DESC "${DOCS}docs/notas.txt")" 10 'caminho-fora-do-filtro:docs/notas\.txt'
expect "mini: um .md entregue e um .db na mesma bead — o .db segura" "$(DESC "${DOCS}docs/guia.md e queue.db")" 10 'caminho-fora-do-filtro:queue\.db'
expect "mini: .md entregue + .md sinalizado — só o sinalizado vira motivo" "$(DESC "${DOCS}docs/guia.md e docs/sinalizado.md")" 10 '"reasons": \["caminho-fora-do-filtro:docs/sinalizado\.md"\]'
expect "unknown: só doc citado (sem código nem teste) deixa de ser mini, mas segue sem prova" "$(DESC 'ajustar docs/runbooks/guia.md')" 11 'sem-prova-de-codigo-e-teste.*via-espelho'
expect "unknown: .md entregue pelo espelho em docs/tests/ NÃO é teste (casa tests?/ mas não é prova)" "$(DESC 'ajustar lib/x.py conforme docs/tests/plan.md')" 11 'sem-prova-de-codigo-e-teste.*via-espelho:docs/tests/plan\.md'
expect "unknown: idem em docs/test/ (singular)" "$(DESC 'ajustar lib/x.py conforme docs/test/README.md')" 11 'sem-prova-de-codigo-e-teste.*via-espelho:docs/test/README\.md'
expect "mini: telefone no texto vence o espelho" "$(DESC "${DOCS}docs/guia.md (31) 98876-5432")" 10 '"reasons": \["dado-no-texto"\]'
expect "mini: palavra de banco vence o espelho (mole)" "$(DESC "${DOCS}docs/guia.md abre um sqlite")" 10 'moles:banco-de-dados'
expect "node:ok + .md entregue" "$(labels "$(DESC 'ajustar docs/runbooks/guia.md')" '["node:ok"]')" 0 '"basis": "label".*via-espelho'
printf '# so comentario\ndocs/runbooks/*.md\n' > "$T/macs-md.txt"
export WA_NODE_MAC_ONLY="$T/macs-md.txt"
expect "mini: .md entregue mas na lista só-Mac segue só-Mac" "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'so-no-mac:docs/runbooks/guia\.md'
unset WA_NODE_MAC_ONLY
# o espelho não ajuda quando o texto não cita .md fora da lista: nem é consultado (espelho que pendura não atrasa nem muda o caso)
export WA_NODE_MIRROR="$T/mirror-pendura" WA_NODE_MIRROR_TIMEOUT=1
expect "o espelho só é consultado quando há .md fora do rsync (bead sem doc não paga)" "$GOOD" 0 '"verdict": "node"'
unset WA_NODE_MIRROR_TIMEOUT
# falhas de leitura do espelho: voltam ao filtro do rsync (mini, como antes) e dizem o motivo em `info`; NUNCA viram "o espelho entrega"
chega() { # chega <rótulo> <stub do espelho> <motivo esperado em info> [VAR=valor]   (sem subshell: ok/bad contam em globais)
  export WA_NODE_MIRROR="$T/$2"; [ -n "${4:-}" ] && export "$4"
  expect "espelho que falha ($1): volta ao filtro do rsync e diz '$3'" "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 "caminho-fora-do-filtro:docs/runbooks/guia\\.md.*espelho-ilegivel:$3"
  [ -n "${4:-}" ] && unset "${4%%=*}"; export WA_NODE_MIRROR="$T/mirror-ok"; return 0; }
chega "script ausente" espelho-ausente espelho-sem-resposta
chega "sai com rc 75 (varredura ainda não cobre as pontas) mesmo imprimindo um spec bom" mirror-75 espelho-rc-75
chega "saída vazia" mirror-vazio espelho-formato
chega "spec sem a raiz /*" mirror-sem-raiz espelho-formato
chega "spec com linha que não é negação" mirror-torta espelho-formato
chega "spec curto demais (filtro cortado)" mirror-curto espelho-filtro-cortado
chega "spec sem a família *.parquet" mirror-sem-parquet espelho-filtro-cortado
chega "spec que nega TODO .md (o canário de doc é negado)" mirror-nega-md espelho-canario-errado
chega "não responde no prazo" mirror-pendura espelho-sem-resposta WA_NODE_MIRROR_TIMEOUT=1
chega "git inexistente" mirror-ok espelho-git-sem-resposta WA_NODE_GIT=$T/nao-existe-git
chega "git que não nega nada (canário de dado passa)" mirror-ok espelho-canario-errado WA_NODE_GIT=$T/git-mudo
chega "git que falha (rc 128)" mirror-ok espelho-git-rc-128 WA_NODE_GIT=$T/git-quebrado
# o rsync "só negações" falha mas o estrito não: o espelho não é consultado e o caso volta ao filtro
printf '#!/bin/sh\ncase "$4" in *filtro-so-negacoes*) exit 1;; esac\nexec rsync "$@"\n' > "$T/rs-so-neg-falha"; chmod +x "$T/rs-so-neg-falha"   # só a visão "só negações" falha (rc 1)
stub rs-so-neg-vaza 'case "$4" in *filtro-so-negacoes*) rsync "$@"; printf "shared/zz_wa_node_canary.md\nlogs/zz_wa_node_canary.md\n"; exit 0;; esac; exec rsync "$@"'
export WA_NODE_RSYNC="$T/rs-so-neg-falha"; expect "visão 'só negações' do rsync que falha: volta ao filtro do rsync" "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:rsync-rc-1'; unset WA_NODE_RSYNC
# prazo do espelho ilegível volta ao padrão e não derruba
export WA_NODE_MIRROR_TIMEOUT=abc; expect "prazo do espelho ilegível volta ao padrão (20) e não derruba" "$(DESC "${DOCS}docs/runbooks/guia.md")" 0 'via-espelho'; unset WA_NODE_MIRROR_TIMEOUT
export WA_NODE_MIRROR="$T/espelho-ausente"

# ---- teste derivado (ga-2hd02v.3.15, regra 6): código citado e NENHUM teste citado -> o teste que o repo do WA já tem. O repo é de mentira: origin/main = o 1º commit; o 2º só existe no HEAD (o nó não o tem).
RP="$T/wa-repo"; mkdir -p "$RP"
gw() { env -i HOME="$T" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$RP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
wf() { mkdir -p "$RP/$(dirname "$1")"; printf '%s\n' "$2" > "$RP/$1"; }   # wf <caminho> <conteúdo>
gw init -q
gwold() { env -i HOME="$T" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$RP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }   # commit de 2020: fora da janela das irmãs
# o commit velho é o 1º da história de propósito: com ele no topo o `--since` cortaria também os commits novos que vêm abaixo
wf lib/velha_mod.py "# velha_mod"; wf tests/test_velha_mod.py "velha_mod"; gw add lib/velha_mod.py tests/test_velha_mod.py && gwold commit -q -m "feat(wa-par5.1): velha_mod" || bad "commit velho das irmas nao montado"
# irmãs (ga-2hd02v.3.20, regra 7): commits `feat(wa-par1.1)`... que tocam arquivos; wa-par1.3 (sem caminho nem nome no texto) herda os de wa-par1.1/.2; wa-par9.1 é de OUTRO pai; wa-par3.1 criou um arquivo que depois saiu da árvore; wa-par4.1 tocou 11 arquivos
wf lib/irma_mod.py "# irma_mod"; wf tests/test_irma_mod.py "irma_mod"; gw add lib/irma_mod.py tests/test_irma_mod.py && gw commit -q -m "feat(wa-par1.1): irma_mod"
wf lib/irma_two.py "# irma_two"; gw add lib/irma_two.py && gw commit -q -m "fix(wa-par1.2): irma_two"
wf lib/outro_mod.py "# outro_mod"; gw add lib/outro_mod.py && gw commit -q -m "fix(wa-par9.1): outro_mod"
wf lib/removido_mod.py "# removido_mod"; gw add lib/removido_mod.py && gw commit -q -m "feat(wa-par3.1): removido_mod"; gw rm -q lib/removido_mod.py && gw commit -q -m "chore: remove removido_mod"
for i in 01 02 03 04 05 06 07 08 09 10 11; do wf "lib/mega_$i.py" "# mega_$i"; done; gw add lib && gw commit -q -m "feat(wa-par4.1): mega" || bad "commits das irmas nao montados"
for m in foo_parser bar_service bar_service_extra utils abcd silent_mod subs_mod orfa_unica flag_mod mac_mod tok_mod ext_mod inner_mod boundary many_mod huge_mod cap_a cap_b cap_c cap_d cap_e late_mod; do wf "lib/$m.py" "# $m"; done
wf lib/js_mod.js "// js_mod"; wf scripts/run_job.sh "# run_job"; wf lib/dash-mod.py "# dash-mod"; wf tests/test_dash-mod_wa.py "dash-mod"; wf lib/css_mod.css "/* css_mod */"; wf tests/test_css_mod_wa.py "css_mod"   # nome com hífen: fora do formato de módulo
wf tests/test_foo_parser.py "from lib.foo_parser import parse"; wf tests/test_foo_parser_extra_wa_x1.py "import foo_parser"; wf tests/auto_response/test_foo_parser_sub.py "foo_parser"
wf tests/test_bar_service.py "bar_service"; wf tests/test_bar_service_extra_casos.py "bar_service bar_service_extra"   # o 2º é do módulo bar_service_extra, que também existe E cita bar_service como palavra inteira (como os testes irmãos reais): só a regra do módulo mais longo o tira de bar_service
wf tests/test_utils_algo.py "utils"; wf tests/test_abcd_x.py "abcd"
wf tests/test_silent_mod_wa_q.py "nada aqui"; wf tests/test_subs_mod_wa_q.py "subs_module_other"   # nome certo, conteúdo que não cita / que só tem o módulo dentro de outra palavra
wf tests/test_flag_mod.py "flag_mod"; wf tests/test_mac_mod.py "mac_mod"; wf tests/test_tok_mod_token.js "tok_mod"
wf tests/test_js_mod_wa_1.cjs "js_mod"; wf tests/test_run_job.py "run_job"; wf tests/test_novo_modulo_wa_n.py "novo_modulo"   # novo_modulo: teste existe, código NÃO
wf tests/test_old_inner_mod_wa.py "inner_mod"; wf tests/test_boundaryx_wa.py "boundary"; wf tests/test_ext_mod.json "ext_mod"
for i in 1 2 3 4 5 6 7; do wf "tests/test_many_mod_$i.py" "many_mod"; done
for i in $(seq -w 1 30); do wf "tests/test_huge_mod_$i.py" "huge_mod"; done
for m in cap_a cap_b cap_c cap_d cap_e; do for i in $(seq -w 1 21); do wf "tests/test_${m}_$i.py" "$m"; done; done
# nome solto (ga-2hd02v.3.17): atalho de arquivo em outra pasta. loose_page.html é único; dup_page.html existe em 2 pastas; raiz_page.html mora na raiz; dupr_page.html mora na raiz E em templates/; solto_run.sh tem teste; shared/notas_solto.md é pasta que nunca sai
wf templates/loose_page.html "<p>x</p>"; wf templates/dup_page.html "<p>a</p>"; wf daemons/templates/dup_page.html "<p>b</p>"; wf raiz_page.html "<p>r</p>"; wf dupr_page.html "<p>r</p>"; wf templates/dupr_page.html "<p>t</p>"; wf "templates/com espaco/pagina_estranha.html" "<p>e</p>"
wf scripts/solto_run.sh "# solto_run"; wf tests/test_solto_run.py "solto_run"; wf shared/notas_solto.md "# notas"; wf fixtures/solto_dado.json "{}"
# regra 7 (ga-2hd02v.3.20): código que a bead NOMEIA sem caminho. ficha_donos/form_fill têm teste; dupmod_x mora em 2 pastas; fora_mod mora em shared/ (nunca sai); mac_code_mod entra na lista mac-only do caso; sem_teste_mod não tem teste; ambig_mod mora em 4 pastas; db_x tem nome curto; limcap_NN são 12 módulos
wf lib/ficha_donos.py "# ficha_donos"; wf tests/test_ficha_donos.py "ficha_donos"; wf lib/form_fill.py "# form_fill"; wf tests/test_form_fill.py "form_fill"
wf lib/dupmod_x.py "# dupmod_x"; wf daemons/dupmod_x.py "# dupmod_x"; wf tests/test_dupmod_x.py "dupmod_x"
wf shared/fora_mod.py "# fora_mod"; wf tests/test_fora_mod.py "fora_mod"; wf lib/mac_code_mod.py "# mac_code_mod"; wf tests/test_mac_code_mod.py "mac_code_mod"
wf lib/sem_teste_mod.py "# sem_teste_mod"; wf lib/db_x.py "# db_x"; wf tests/test_db_x.py "db_x"
for d in pkg1 pkg2 pkg3 pkg4; do wf "$d/ambig_mod.py" "# ambig_mod"; done; wf tests/test_ambig_mod.py "ambig_mod"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do wf "lib/limcap_$i.py" "# limcap_$i"; wf "tests/test_limcap_$i.py" "limcap_$i"; done
gw add -A && gw commit -q -m 1 && gw update-ref refs/remotes/origin/main HEAD || bad "repo de mentira do WA não montado"
wf tests/test_late_mod.py "late_mod"; gw add -A && gw commit -q -m 2   # o teste de late_mod só existe no HEAD, não em origin/main
git_ok=$(gw rev-parse --verify -q refs/remotes/origin/main >/dev/null && gw ls-tree -r --name-only origin/main | grep -c 'test_foo_parser'); [ "$git_ok" = 3 ] && ok "repo de mentira do WA montado (origin/main tem 3 testes de foo_parser; o HEAD tem um a mais em late_mod)" || bad "repo de mentira do WA errado ($git_ok)"
mkdir -p "$T/wa-repo-vazio"; env -i HOME="$T" PATH="$PATH" git -C "$T/wa-repo-vazio" init -q
env -i HOME="$T" PATH="$PATH" git -C "$T/wa-repo-vazio" update-ref refs/remotes/origin/main "$(env -i HOME="$T" PATH="$PATH" git -C "$T/wa-repo-vazio" -c user.email=t@t -c user.name=t commit-tree "$(env -i HOME="$T" PATH="$PATH" git -C "$T/wa-repo-vazio" hash-object -t tree /dev/null)" -m vazio)"   # origin/main existe e a árvore é VAZIA
stub git-grep-quebra 'for a in "$@"; do [ "$a" = grep ] && exit 2; done; exec git "$@"'          # só o `git grep` falha (rc 2)
stub git-grep-mudo 'for a in "$@"; do [ "$a" = grep ] && exit 0; done; exec git "$@"'            # `git grep` sai 0 sem imprimir nada (o que o git nunca faz)
stub git-lento 'for a in "$@"; do [ "$a" = ls-tree ] && sleep 6; done; exec git "$@"'
printf '# so comentario\ntests/test_mac_mod*.py\n' > "$T/macs-derivado.txt"
grep -v -F '[Kk][Ee][Nn]' "$T/spec.txt" > "$T/spec-sem-token.txt"; stub mirror-sem-token 'cat "'"$T"'/spec-sem-token.txt"'   # o espelho SEM as regras de token: só o filtro do rsync nega test_tok_mod_token.js
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
SEMNOTA='"info": \[\]\}$'   # unknown SEM nota: o repo respondeu e não há teste (vazio é um estado legítimo)
expect "derivado: node com basis derivado, 3 testes (um em subpasta) e os pares em info" "$(DESC 'Corrigir lib/foo_parser.py quando a entrada vem vazia.')" 0 '"verdict": "node", "basis": "derivado", "reasons": \["prova-teste-derivado:3-teste\(s\)\+1-codigo\(s\)"\].*"info": \["teste-derivado:lib/foo_parser\.py=tests/auto_response/test_foo_parser_sub\.py", "teste-derivado:lib/foo_parser\.py=tests/test_foo_parser\.py", "teste-derivado:lib/foo_parser\.py=tests/test_foo_parser_extra_wa_x1\.py"\]\}$'
expect "derivado: o teste citado continua dando basis text (a regra 5 vem antes)" "$(DESC 'Corrigir lib/foo_parser.py com tests/test_foo_parser.py')" 0 '"basis": "text".*prova-no-texto'
expect "derivado: node:ok continua dando basis label" "$(labels "$(DESC 'Corrigir lib/foo_parser.py')" '["node:ok"]')" 0 '"basis": "label"'
expect "derivado: teste citado SEM código citado não deriva nada" "$(DESC 'rodar tests/test_foo_parser.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: código citado sem teste no repo -> unknown sem nota" "$(DESC 'ajustar lib/orfa_unica.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: código que NÃO existe em origin/main não ganha o teste de nome igual (test_novo_modulo existe)" "$(DESC 'criar lib/novo_modulo.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: só o código que tem teste conta; o sem teste não atrapalha nem entra na contagem" "$(DESC 'ajustar lib/foo_parser.py e lib/orfa_unica.py')" 0 'prova-teste-derivado:3-teste\(s\)\+1-codigo\(s\)'
expect "derivado: dois códigos com teste somam" "$(DESC 'ajustar lib/foo_parser.py e lib/bar_service.py')" 0 'prova-teste-derivado:4-teste\(s\)\+2-codigo\(s\)'
expect "derivado: test_bar_service_extra_* é de bar_service_extra (módulo mais longo que existe), não de bar_service" "$(DESC 'ajustar lib/bar_service.py')" 0 'prova-teste-derivado:1-teste\(s\)\+1-codigo\(s\).*"teste-derivado:lib/bar_service\.py=tests/test_bar_service\.py"\]\}$'
expect "derivado: e o módulo mais longo fica com o dele" "$(DESC 'ajustar lib/bar_service_extra.py')" 0 'prova-teste-derivado:1-teste\(s\)\+1-codigo\(s\).*=tests/test_bar_service_extra_casos\.py"\]\}$'
expect "derivado: nome genérico (utils) não prova nada" "$(DESC 'ajustar lib/utils.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: nome curto (4 letras) não prova nada" "$(DESC 'ajustar lib/abcd.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: nome do teste certo, conteúdo que NÃO cita o módulo" "$(DESC 'ajustar lib/silent_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: conteúdo que só tem o módulo dentro de outra palavra (subs_module_other) não cita" "$(DESC 'ajustar lib/subs_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: módulo no MEIO do nome do teste (test_old_inner_mod) não é do módulo" "$(DESC 'ajustar lib/inner_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: prefixo sem o _ (test_boundaryx) não é do módulo boundary" "$(DESC 'ajustar lib/boundary.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: .css citado não ganha teste por nome (só py/sh/js/mjs/cjs/ts)" "$(DESC 'ajustar lib/css_mod.css')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: nome de módulo com hífen (fora do formato) não prova nada" "$(DESC 'ajustar lib/dash-mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: extensão que não é de teste (test_ext_mod.json) não conta" "$(DESC 'ajustar lib/ext_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: teste que a varredura de conteúdo do espelho sinalizou NÃO é teste que o nó tem" "$(DESC 'ajustar lib/flag_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: teste só no HEAD (não em origin/main) não conta: o espelho entrega origin/main" "$(DESC 'ajustar lib/late_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: teste que o filtro do rsync nega (test_tok_mod_token.js; o espelho também) não conta" "$(DESC 'ajustar lib/tok_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
export WA_NODE_MIRROR="$T/mirror-sem-token"; expect "derivado: teste que SÓ o filtro do rsync nega (o espelho não tem a regra de token) também não conta" "$(DESC 'ajustar lib/tok_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"; export WA_NODE_MIRROR="$T/mirror-ok"
export WA_NODE_MAC_ONLY="$T/macs-derivado.txt"
expect "derivado: teste na lista mac-only não conta" "$(DESC 'ajustar lib/mac_mod.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
unset WA_NODE_MAC_ONLY
expect "derivado: .js com teste .cjs" "$(DESC 'ajustar lib/js_mod.js')" 0 '"basis": "derivado".*test_js_mod_wa_1\.cjs'
expect "derivado: script .sh com teste .py" "$(DESC 'ajustar scripts/run_job.sh')" 0 '"basis": "derivado".*test_run_job\.py'
expect "derivado: mais de 6 pares: 6 em info e o resto contado (teste-derivado-mais)" "$(DESC 'ajustar lib/many_mod.py')" 0 'prova-teste-derivado:7-teste\(s\)\+1-codigo\(s\).*test_many_mod_6\.py", "teste-derivado-mais:1"\]\}$'
expect "derivado: teto de 25 testes por módulo" "$(DESC 'ajustar lib/huge_mod.py')" 0 'prova-teste-derivado:25-teste\(s\)\+1-codigo\(s\).*"teste-derivado-mais:19"\]\}$'
expect "derivado: teto de 100 candidatos no total (5 módulos x 21 testes)" "$(DESC 'ajustar lib/cap_a.py lib/cap_b.py lib/cap_c.py lib/cap_d.py lib/cap_e.py')" 0 'prova-teste-derivado:100-teste\(s\)\+5-codigo\(s\)'
expect "freio: lead no texto manda ao mini (prova fraca), com os pares em info" "$(DESC 'Corrigir lib/foo_parser.py; o lead some da lista')" 10 '"verdict": "mini", "basis": "", "reasons": \["freio-derivado:dado-de-lead"\].*teste-derivado:lib/foo_parser\.py='
expect "freio: envio no texto manda ao mini" "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 '"reasons": \["freio-derivado:envio-whatsapp"\]'
expect "freio: lead e envio juntos, na ordem da lista" "$(DESC 'Corrigir lib/foo_parser.py: o lead recebe o envio duplicado')" 10 '"reasons": \["freio-derivado:dado-de-lead,envio-whatsapp"\]'
expect "freio: palavras informativas que NÃO são da lista (deploy, tela) não bloqueiam a prova derivada" "$(DESC 'Corrigir lib/foo_parser.py no deploy da tela')" 0 '"basis": "derivado"'
expect "freio: sem prova derivada o lead no texto não muda o unknown (continua não sei, não vira mini)" "$(DESC 'ajustar lib/orfa_unica.py; o lead some')" 11 'sem-prova-de-codigo-e-teste'
expect "derivado: palavra mole (banco) ainda vence" "$(DESC 'Corrigir lib/foo_parser.py que abre um sqlite')" 10 'moles:banco-de-dados'
expect "derivado: caminho duro (.db) ainda vence" "$(DESC 'Corrigir lib/foo_parser.py e queue.db')" 10 'caminho-fora-do-filtro:queue\.db'
expect "derivado: telefone no texto ainda vence" "$(DESC 'Corrigir lib/foo_parser.py (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
# falhou/ilegível: unknown COM a nota (nunca node, nunca o mesmo resultado do vazio)
NOTA() { printf 'sem-prova-de-codigo-e-teste.*"info": \\["teste-derivado-ilegivel:%s"\\]\\}$' "$1"; }
FP=$(DESC 'Corrigir lib/foo_parser.py quando a entrada vem vazia.')
export WA_NODE_REPO="$T/wa-repo-ausente";  expect "derivado: repo inexistente -> unknown com a nota (não 'sem teste')" "$FP" 11 "$(NOTA repo-git-rc-128)"; export WA_NODE_REPO="$RP"
export WA_NODE_REPO_REF=origin/zz;        expect "derivado: ref inexistente -> unknown com a nota" "$FP" 11 "$(NOTA repo-git-rc-128)"; unset WA_NODE_REPO_REF
export WA_NODE_REPO_REF=--oops;           expect "derivado: ref com cara de opção do git é recusada antes de chamar o git" "$FP" 11 "$(NOTA repo-ref-invalida)"; unset WA_NODE_REPO_REF
export WA_NODE_REPO="$T/wa-repo-vazio";    expect "derivado: árvore VAZIA em origin/main é ilegível (a real nunca é vazia), não 'sem teste'" "$FP" 11 "$(NOTA repo-vazio)"; export WA_NODE_REPO="$RP"
export WA_NODE_GIT="$T/nao-existe-git";    expect "derivado: git inexistente -> unknown com a nota" "$FP" 11 "$(NOTA repo-git-sem-resposta)"; unset WA_NODE_GIT
export WA_NODE_GIT="$T/git-lento" WA_NODE_REPO_TIMEOUT=1; expect "derivado: git que não responde no prazo -> unknown com a nota" "$FP" 11 "$(NOTA repo-git-sem-resposta)"; unset WA_NODE_GIT WA_NODE_REPO_TIMEOUT
export WA_NODE_GIT="$T/git-grep-quebra";   expect "derivado: git grep que falha (rc 2) -> unknown com a nota, não 'nenhum teste cita'" "$FP" 11 "$(NOTA repo-grep-rc-2)"; unset WA_NODE_GIT
export WA_NODE_GIT="$T/git-grep-mudo";     expect "derivado: git grep que sai 0 sem nome algum -> unknown com a nota" "$FP" 11 "$(NOTA repo-grep-ilegivel)"; unset WA_NODE_GIT
export WA_NODE_MIRROR="$T/mirror-75";      expect "derivado: espelho em atualização (rc 75) -> unknown com a nota, nunca 'o nó tem o teste'" "$FP" 11 "$(NOTA espelho-rc-75)"; export WA_NODE_MIRROR="$T/mirror-ok"
export WA_NODE_REPO_TIMEOUT=abc;           expect "derivado: prazo do repo ilegível volta ao padrão (20) e não derruba" "$FP" 0 '"basis": "derivado"'; unset WA_NODE_REPO_TIMEOUT
export WA_NODE_REPO="$T/wa-repo-ausente" WA_NODE_MIRROR="$T/espelho-ausente"

# ---- nome solto (ga-2hd02v.3.17): `loose_page.html` sem pasta é atalho de templates/loose_page.html. Troca só se for inequívoco e o caminho trocado passa pelo MESMO filtro/espelho; dado nunca é trocado.
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
SOLTO_TESTE='tests/test_x.py'
expect "solto: html solto vira o único arquivo com esse nome na árvore (e passa pelo filtro)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar loose_page.html")" 0 '"verdict": "node".*"paths": \["lib/x\.py", "tests/test_x\.py", "templates/loose_page\.html"\].*caminho-solto:loose_page\.html=templates/loose_page\.html'
expect "solto: nome que não existe em lugar algum da árvore -> segue solto (mini), SEM nota (vazio é um estado legítimo)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar nao_existe_em_lugar_algum.html")" 10 'caminho-fora-do-filtro:nao_existe_em_lugar_algum\.html.*"info": \["tela-ao-vivo"\]\}$'
expect "solto: dois arquivos com o nome na árvore e nenhum citado -> segue solto (mini), sem nota de ilegível" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar dup_page.html")" 10 'caminho-fora-do-filtro:dup_page\.html.*"info": \["tela-ao-vivo"\]\}$'
expect "solto: dois na árvore mas a bead cita UM com pasta -> é esse (a árvore lida confirma que não há arquivo da raiz com o nome)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html (dup_page.html)")" 0 '"paths": \["lib/x\.py", "tests/test_x\.py", "templates/dup_page\.html"\].*caminho-solto:dup_page\.html=templates/dup_page\.html'
expect "solto: a bead cita DOIS com pasta e o nome solto -> não sei qual: segue solto (mini)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html e daemons/templates/dup_page.html (dup_page.html)")" 10 'caminho-fora-do-filtro:dup_page\.html'
expect "solto: a bead cita templates/dupr_page.html mas o repo TEM dupr_page.html na raiz -> o solto pode ser o da raiz: não troca, segue solto (mini)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dupr_page.html (dupr_page.html)")" 10 'caminho-fora-do-filtro:dupr_page\.html'
expect "solto: o arquivo mora na RAIZ do repo (o filtro não manda) -> continua mini com o próprio nome" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar raiz_page.html")" 10 'caminho-fora-do-filtro:raiz_page\.html'
expect "solto: o caminho trocado é julgado pelo mesmo filtro (pasta que nunca sai) -> mini com o caminho REAL na razão" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar notas_solto.md")" 10 'caminho-fora-do-filtro:shared/notas_solto\.md'
expect "solto: caminho real fora do formato seguro (espaço) não é adotado -> segue solto (mini)" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar pagina_estranha.html")" 10 'caminho-fora-do-filtro:pagina_estranha\.html'
expect "solto: nome solto de DADO (.json) nunca é trocado, mesmo único na árvore" "$(DESC "lib/x.py e $SOLTO_TESTE: ler solto_dado.json")" 10 'caminho-fora-do-filtro:solto_dado\.json'
expect "solto: código solto ganha o caminho real e, com ele, o teste derivado" "$(DESC 'ajustar solto_run.sh')" 0 '"basis": "derivado".*caminho-solto:solto_run\.sh=scripts/solto_run\.sh.*teste-derivado:scripts/solto_run\.sh=tests/test_solto_run\.py'
export WA_NODE_REPO="$T/wa-repo-ausente"
expect "solto: árvore ilegível (repo inexistente) -> segue solto (mini) COM a nota; falhou não é 'vazio'" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar loose_page.html")" 10 'caminho-fora-do-filtro:loose_page\.html.*caminho-solto-ilegivel:repo-git-rc-128'
# (ga-2hd02v.3.17, gate 1) ANTES: "com a árvore ilegível o caminho citado com pasta ainda resolve (não precisa da árvore)" -> node. Sem a árvore não dá para saber se o solto é o arquivo da RAIZ (aí o citado seria outro
# arquivo): palpite não é prova, e falhou não pode virar node. Agora segue solto = mini, COM a nota; o caso foi invertido de propósito
expect "solto: com a árvore ilegível o caminho citado com pasta NÃO é adotado (não dá para saber se o solto é o da raiz) -> segue solto (mini) COM a nota" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/loose_page.html (loose_page.html)")" 10 'caminho-fora-do-filtro:loose_page\.html.*caminho-solto-ilegivel:repo-git-rc-128'
export WA_NODE_REPO="$T/wa-repo-ausente" WA_NODE_MIRROR="$T/espelho-ausente"

# ---- caminho derivado (ga-2hd02v.3.20, regra 7): a bead NÃO cita código com caminho, mas NOMEIA o módulo (snake_case/hífen) ou é irmã de beads cujos commits tocaram o código -> o caminho que o repo do WA já tem, julgado pelos MESMOS filtros do citado
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
DESCI() { printf '{"id":"%s","title":"t","description":"%s"}' "$1" "$2"; }   # DESCI <id> <texto>: bead com id explícito (o das irmãs vem do id)
CUSTO0='"custo": \{"ms": [0-9]+, "derivacao_ms": 0, "cache": "-"\}'
cachef() { "$PY" -I -c 'import hashlib,sys; print("sib-"+hashlib.sha1(sys.argv[1].encode()).hexdigest()[:20]+".json")' "$1"; }
seedc() { # seedc <dir> <pai> <idade em s> <lista json> [pai gravado no arquivo]: um cache de irmãs escrito à mão
  mkdir -p "$1"; "$PY" -I -c 'import json,sys,time; json.dump({"parent": sys.argv[4], "ts": time.time()-float(sys.argv[2]), "files": json.loads(sys.argv[3])}, open(sys.argv[1], "w"))' "$1/$(cachef "$2")" "$3" "$4" "${5:-$2}"
}
N_OK='"verdict": "node", "basis": "derivado"'
expect "caminho: nome snake_case no texto vira o código do repo + o teste que o repo tem -> node derivado, com a origem e o par em info e paths vazio" "$(DESC 'revisar ficha_donos quando a entrada vem vazia')" 0 "$N_OK, \"reasons\": \[\"prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\)\"\], \"paths\": \[\], \"tests\": \[\].*\"info\": \[\"caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py\", \"teste-derivado:lib/ficha_donos\.py=tests/test_ficha_donos\.py\"\]\}\$"
expect "caminho: nome com hífen (form-fill) vale como form_fill" "$(DESC 'revisar o form-fill quando o campo vem vazio')" 0 "$N_OK.*caminho-derivado:nome:form_fill=lib/form_fill\.py"
expect "caminho: maiúscula no texto (Ficha_Donos) acha o mesmo arquivo" "$(DESC 'revisar a Ficha_Donos quando vem vazia')" 0 "$N_OK.*caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py"
expect "caminho: um nome que existe em 2 pastas deriva os 2 (até 3), cada um com o teste do módulo" "$(DESC 'revisar dupmod_x quando vem vazio')" 0 'prova-caminho-derivado:1-teste\(s\)\+2-codigo\(s\).*"caminho-derivado:nome:dupmod_x=daemons/dupmod_x\.py", "caminho-derivado:nome:dupmod_x=lib/dupmod_x\.py"'
expect "caminho: teste CITADO + código nomeado -> node, o teste citado é a prova (sem par teste-derivado em info)" "$(DESC 'tests/test_x.py cobre sem_teste_mod quando vem vazio')" 0 "$N_OK, \"reasons\": \[\"prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\)\"\], \"paths\": \[\"tests/test_x\.py\"\].*\"info\": \[\"caminho-derivado:nome:sem_teste_mod=lib/sem_teste_mod\.py\"\]\}\$"
expect "caminho: código com nome mas SEM teste e nenhum teste citado -> unknown, e o que foi derivado fica em info" "$(DESC 'revisar sem_teste_mod quando vem vazio')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-derivado:nome:sem_teste_mod=lib/sem_teste_mod\.py"\]\}$'
expect "caminho: nome que não existe no repo -> unknown SEM nota (vazio é um estado legítimo)" "$(DESC 'revisar modulo_inexistente quando vem vazio')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: texto sem nome nenhum -> unknown SEM nota e a regra 7 nem roda (derivacao_ms 0)" "$(DESC 'melhorar a mensagem de erro do importador')" 11 "sem-prova-de-codigo-e-teste.*$CUSTO0.*$SEMNOTA"
expect "caminho: nome curto (db_x) não vale como nome: nem consulta o repo" "$(DESC 'revisar db_x quando vem vazio')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: nome de 4 arquivos (ambig_mod) é ambíguo: não deriva nenhum, e diz isso" "$(DESC 'revisar ambig_mod quando vem vazio')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-derivado-ambiguo:ambig_mod=4"\]\}$'
expect "caminho: o que tem pasta (docs/ficha_donos) é caminho, não nome solto" "$(DESC 'ver a pasta docs/ficha_donos quando vem vazia')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: nome seguido de ponto+letras (ficha_donos.xyz) é arquivo, não nome" "$(DESC 'ver ficha_donos.xyz quando vem vazio')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: nome seguido de barra (ficha_donos/algo) é pasta, não nome" "$(DESC 'ver ficha_donos/algo quando vem vazio')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: código CITADO sem teste NÃO é re-derivado por nome (a regra 7 só roda sem código citado)" "$(DESC 'ajustar lib/sem_teste_mod.py e a ficha_donos')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "caminho: 12 nomes (mais que o teto de 10 arquivos) -> a bead não é sobre um módulo só: nada derivado, e diz isso" "$(DESC 'revisar limcap_01 limcap_02 limcap_03 limcap_04 limcap_05 limcap_06 limcap_07 limcap_08 limcap_09 limcap_10 limcap_11 limcap_12')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-derivado-demais:12"\]\}$'
expect "caminho: 10 nomes (o teto) ainda derivam; em info 6 + o resto contado" "$(DESC 'revisar limcap_01 limcap_02 limcap_03 limcap_04 limcap_05 limcap_06 limcap_07 limcap_08 limcap_09 limcap_10')" 0 'prova-caminho-derivado:10-teste\(s\)\+10-codigo\(s\).*"caminho-derivado-mais:4"'
# o caminho derivado passa pelo MESMO filtro do citado: o que o rsync segura (shared/) ou a lista mac-only segura manda ao mini; derivar nunca afrouxa regra
expect "caminho: código derivado que o filtro do rsync segura (shared/) -> mini, com o caminho na razão" "$(DESC 'revisar fora_mod quando vem vazio')" 10 '"reasons": \["caminho-derivado-fora-do-filtro:shared/fora_mod\.py"\]'
printf '# so no mac\nlib/mac_code_mod.py\n' > "$T/macs-derivado7.txt"
expect "caminho: controle — mac_code_mod sem a lista mac-only é node" "$(DESC 'revisar mac_code_mod quando vem vazio')" 0 "$N_OK"
export WA_NODE_MAC_ONLY="$T/macs-derivado7.txt"
expect "caminho: código derivado que está na lista mac-only -> mini, com o caminho na razão" "$(DESC 'revisar mac_code_mod quando vem vazio')" 10 '"reasons": \["caminho-derivado-so-no-mac:lib/mac_code_mod\.py"\]'
unset WA_NODE_MAC_ONLY
expect "caminho: um derivado fora do filtro entre dois que passam leva a bead toda ao mini" "$(DESC 'revisar ficha_donos e fora_mod quando vem vazio')" 10 '"reasons": \["caminho-derivado-fora-do-filtro:shared/fora_mod\.py"\]'
# palavras duras/moles e freios valem como sempre
expect "caminho-freio: lead no texto manda ao mini (prova fraca), com a origem em info" "$(DESC 'revisar ficha_donos: o lead some da lista')" 10 '"reasons": \["freio-derivado:dado-de-lead"\].*caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py'
expect "caminho-freio: envio no texto manda ao mini" "$(DESC 'revisar ficha_donos antes de enviar a mensagem')" 10 '"reasons": \["freio-derivado:envio-whatsapp"\]'
expect "caminho: palavra mole (banco) ainda vence" "$(DESC 'revisar ficha_donos que abre um sqlite')" 10 'moles:banco-de-dados'
expect "caminho: telefone no texto ainda vence" "$(DESC 'revisar ficha_donos (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "caminho: node:ok continua dando basis label (a regra 7 nem roda)" "$(labels "$(DESC 'revisar ficha_donos')" '["node:ok"]')" 0 '"basis": "label"'
# falhou/ilegível: unknown COM a nota, nunca node e nunca o mesmo resultado do vazio
NOTA7() { printf 'sem-prova-de-codigo-e-teste.*"info": \\[.*"caminho-derivado-ilegivel:%s"\\]\\}$' "$1"; }   # a nota é a ÚLTIMA de info; o que já se derivou antes de a leitura falhar fica registrado à frente dela
FF=$(DESC 'revisar ficha_donos quando a entrada vem vazia')
export WA_NODE_REPO="$T/wa-repo-ausente"; expect "caminho: repo inexistente -> unknown com a nota (não 'nada derivado')" "$FF" 11 "$(NOTA7 repo-git-rc-128)"; export WA_NODE_REPO="$RP"
export WA_NODE_RSYNC="$T/rs-rc1";         expect "caminho: rsync que falha na hora de julgar o caminho derivado -> unknown com a nota" "$FF" 11 "$(NOTA7 rsync-rc-1)"; unset WA_NODE_RSYNC
export WA_NODE_MAC_ONLY="$T/nao-existe.txt"; expect "caminho: lista mac-only ausente -> unknown com a nota (sem caminho citado a lista nunca era lida: a regra 7 lê por conta própria)" "$FF" 11 "$(NOTA7 mac-only-ilegivel)"; unset WA_NODE_MAC_ONLY
export WA_NODE_GIT="$T/git-grep-quebra";  expect "caminho: git grep que falha ao procurar o teste derivado -> unknown com a nota" "$FF" 11 "$(NOTA7 repo-grep-rc-2)"; unset WA_NODE_GIT
export WA_NODE_MIRROR="$T/mirror-75";     expect "caminho: espelho em atualização ao julgar o teste derivado -> unknown com a nota" "$FF" 11 "$(NOTA7 espelho-rc-75)"; export WA_NODE_MIRROR="$T/mirror-ok"
export WA_NODE_REPO="$T/wa-repo-ausente"; expect "caminho: nome curto com o repo ausente não vira nota (nada a consultar)" "$(DESC 'revisar db_x quando vem vazio')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"; export WA_NODE_REPO="$RP"
# irmãs: o pai vem do id (sem o último .N) ou do campo parent; os arquivos vêm dos commits que citam <pai>.N, só os que ainda existem em origin/main, e passam pelos mesmos filtros
find "$T/cache" -mindepth 1 -delete 2>/dev/null
expect "irmas: bead sem caminho nem nome herda o código dos commits das irmãs (.1 e .2) e o teste que o repo tem; 1ª vez = cache miss" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 "$N_OK, \"reasons\": \[\"prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\)\"\].*\"cache\": \"miss\"\}.*\"info\": \[\"caminho-derivado:irmas=lib/irma_mod\.py\", \"caminho-derivado:irmas=lib/irma_two\.py\", \"teste-derivado:lib/irma_mod\.py=tests/test_irma_mod\.py\"\]\}\$"
[ -f "$T/cache/$(cachef wa-par1)" ] && ok "irmas: o miss gravou o cache do pai wa-par1" || bad "irmas: o miss não gravou o cache"
expect "irmas: 2ª vez, o mesmo pai vem do cache (hit) e dá o mesmo veredito" "$(DESCI wa-par1.4 'corrigir o caso de borda')" 0 "$N_OK.*\"cache\": \"hit\"\}.*caminho-derivado:irmas=lib/irma_mod\.py"
expect "irmas: o campo parent da bead vale quando o id não tem ponto" "$(printf '{"id":"wa-zzz9","parent":"wa-par1","title":"t","description":"corrigir o caso de borda"}')" 0 "$N_OK.*caminho-derivado:irmas=lib/irma_mod\.py"
expect "irmas: pai de outro grupo (wa-par9) não herda o de wa-par1" "$(DESCI wa-par9.2 'corrigir o caso de borda')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-derivado:irmas=lib/outro_mod\.py"\]\}$'
expect "irmas: pai sem nenhum commit (wa-par2) -> unknown SEM nota (vazio é legítimo), e o miss foi medido" "$(DESCI wa-par2.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*\"cache\": \"miss\".*$SEMNOTA"
expect "irmas: id sem ponto e sem campo parent -> nenhuma consulta às irmãs (cache '-') e unknown SEM nota" "$(DESCI wa-par1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$CUSTO0.*$SEMNOTA"
expect "irmas: campo parent com forma estranha é ignorado (nada vai ao git)" "$(printf '{"id":"wa-zzz8","parent":"wa-par1 -x","title":"t","description":"corrigir o caso de borda"}')" 11 "sem-prova-de-codigo-e-teste.*$CUSTO0.*$SEMNOTA"
expect "irmas: arquivo que a irmã criou e que SAIU de origin/main não é derivado" "$(DESCI wa-par3.2 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "irmas: mais de 10 arquivos nas irmãs -> a bead não é sobre um módulo só: nada derivado, e diz isso" "$(DESCI wa-par4.2 'corrigir o caso de borda')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-derivado-demais:11"\]\}$'
expect "irmas: nome no texto + irmãs: as duas origens entram (sem repetir o mesmo arquivo)" "$(DESCI wa-par1.5 'corrigir irma_mod quando vem vazio')" 0 'caminho-derivado:nome:irma_mod=lib/irma_mod\.py", "caminho-derivado:irmas=lib/irma_two\.py"'
# o cache só poupa tempo: o que ele guarda passa pela árvore e pelos filtros como se tivesse saído do git agora; vencido/torto/de outro pai/ilegível = recalcula
seedc "$T/cache-s" wa-parc 60 '["lib/ficha_donos.py"]'
export WA_NODE_CACHE="$T/cache-s"
expect "cache: pai SEM commits no git mas com cache fresco -> usa o cache (hit): prova que o cache é consultado" "$(DESCI wa-parc.1 'corrigir o caso de borda')" 0 "$N_OK.*\"cache\": \"hit\".*caminho-derivado:irmas=lib/ficha_donos\.py"
seedc "$T/cache-s" wa-parv $((7*3600)) '["lib/ficha_donos.py"]'
expect "cache: vencido (7 h) -> recalcula (miss) e o git não tem commit: unknown SEM nota" "$(DESCI wa-parv.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*\"cache\": \"miss\".*$SEMNOTA"
seedc "$T/cache-s" wa-parw 60 '["lib/ficha_donos.py"]' wa-outro
expect "cache: arquivo de cache de OUTRO pai -> recalcula (miss)" "$(DESCI wa-parw.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*\"cache\": \"miss\".*$SEMNOTA"
mkdir -p "$T/cache-s"; echo 'isto nao e json' > "$T/cache-s/$(cachef wa-parx)"
expect "cache: arquivo torto -> recalcula (miss), não derruba" "$(DESCI wa-parx.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*\"cache\": \"miss\".*$SEMNOTA"
seedc "$T/cache-s" wa-pary 60 '["lib/nao_existe_mais.py"]'
expect "cache: arquivo do cache que não está mais em origin/main não é derivado" "$(DESCI wa-pary.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*\"cache\": \"hit\".*$SEMNOTA"
seedc "$T/cache-s" wa-parz 60 '["shared/fora_mod.py"]'
expect "cache: arquivo do cache que o filtro segura -> mini (o cache não tem voz sobre o filtro)" "$(DESCI wa-parz.1 'corrigir o caso de borda')" 10 'caminho-derivado-fora-do-filtro:shared/fora_mod\.py'
export WA_NODE_CACHE="/dev/null/sem-cache"
expect "cache: pasta de cache que não dá para criar -> segue sem cache e diz (nao-gravou), o veredito não muda" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 "$N_OK.*\"cache\": \"nao-gravou\""
# a leitura do git das irmãs que falha: unknown + nota, e NADA vai ao cache (falhou não é 'as irmãs não tocaram em nada')
stub git-log-quebra 'for a in "$@"; do [ "$a" = log ] && exit 2; done; exec git "$@"'
stub git-log-lento 'for a in "$@"; do [ "$a" = log ] && sleep 6; done; exec git "$@"'
export WA_NODE_CACHE="$T/cache-q"
export WA_NODE_GIT="$T/git-log-quebra"; expect "irmas: git log que falha (rc 2) -> unknown com a nota, nunca node" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 11 "$(NOTA7 irmas-git-rc-2)"; unset WA_NODE_GIT
[ ! -e "$T/cache-q" ] && ok "irmas: a falha do git não gravou cache" || bad "irmas: a falha do git gravou cache"
export WA_NODE_GIT="$T/git-log-lento" WA_NODE_SIBLING_TIMEOUT=1; expect "irmas: git log que não responde no prazo próprio -> unknown com a nota" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 11 "$(NOTA7 irmas-git-sem-resposta)"; unset WA_NODE_GIT WA_NODE_SIBLING_TIMEOUT
export WA_NODE_SIBLING_TIMEOUT=abc; expect "irmas: prazo ilegível volta ao padrão e não derruba" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 "$N_OK"; unset WA_NODE_SIBLING_TIMEOUT
expect "irmas: commit da irmã mais velho que a janela (45 dias; o de 2020) não é derivado -> unknown SEM nota (vazio é legítimo)" "$(DESCI wa-par5.2 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
export WA_NODE_SIBLING_DAYS=99999 WA_NODE_CACHE="$T/cache-largo"; expect "irmas: janela larga (WA_NODE_SIBLING_DAYS=99999 vira o teto de 3650 dias) enxerga o commit de 2020 -> node derivado (cache à parte: o pai vem de outra janela). Sem o teto o git, com --since anterior a 1970, devolve zero commits SEM erro" "$(DESCI wa-par5.2 'corrigir o caso de borda')" 0 "$N_OK.*caminho-derivado:irmas=lib/velha_mod\.py"
export WA_NODE_SIBLING_DAYS=abc WA_NODE_CACHE="$T/cache-abc"; expect "irmas: janela ilegível volta aos 45 dias (o commit de 2020 segue fora) e não derruba" "$(DESCI wa-par5.2 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
export WA_NODE_SIBLING_DAYS=0 WA_NODE_CACHE="$T/cache-zero"; expect "irmas: janela 0 vira 1 dia (piso): as irmãs de minutos atrás seguem dentro -> node derivado. Sem o piso, --since=0.days.ago é 'agora' e não sobra commit" "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 "$N_OK"
unset WA_NODE_SIBLING_DAYS; export WA_NODE_CACHE="$T/cache"
export WA_NODE_CACHE="$T/cache"
expect "custo: a saída diz o tempo total e o da regra 7 (>0 quando ela rodou)" "$(DESC 'revisar ficha_donos quando a entrada vem vazia')" 0 '"custo": \{"ms": [0-9]+, "derivacao_ms": [1-9][0-9]*, "cache": "-"\}, "info"'
export WA_NODE_REPO="$T/wa-repo-ausente" WA_NODE_MIRROR="$T/espelho-ausente"

# ---- o classificador não deixa resíduo e só aceita stdin
tmp_residue() { # tmp_residue <classificador> -> nº de itens que sobraram num TMPDIR só dele (a bead cita caminhos, então o classificador cria a árvore temporária)
  local d; d=$(mktemp -d "$T/tmpd.XXXXXX")
  printf '%s' "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" | WA_NODE_FILTER="$REAL_FILTER" WA_NODE_MAC_ONLY="$REAL_MAC" TMPDIR="$d" "$PY" -I "$1" >/dev/null 2>&1
  ls -A "$d" | wc -l | tr -d ' '
}
run_tmp=$(tmp_residue "$CLS_REAL")
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
# Três regras para um mutante valer (cada uma fecha um jeito de o "morreu" ser mentira; os três apareceram nesta bateria):
#   1. o classificador ORIGINAL, no MESMO ambiente, passa o caso designado — senão o mutante "morre" qualquer que seja a mutação (vácuo);
#   2. o ambiente é o do original: o mutante mora em $T, então o filtro e a lista mac-only reais são fixados por env — sem isso ele morria de `filtro-ilegivel`, não da mutação;
#   3. morte por `filtro-ilegivel`/`mac-only-ilegivel` (a menos que o caso designado seja justamente esse) é morte pelo ambiente, e reprova.
mk_mutant() { # mk_mutant <nome> <trecho original> <trecho novo> -> cria $T/mut-<nome>.py; rc 1 se o trecho original não existe
  "$PY" -I - "$CLS_REAL" "$T/mut-$1.py" "$2" "$3" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
}
mutant() { # mutant <nome> <trecho original> <trecho novo> <json> <rc> <regex> [VAR=valor do caso designado]
  local name="$1" json="$4" rc="$5" rx="$6" envspec="${7:-}" M="$T/mut-$1.py"
  mk_mutant "$name" "$2" "$3" || { bad "mutante $name: o trecho original não existe (o classificador mudou? atualize o mutante)"; return; }
  export WA_NODE_FILTER="$REAL_FILTER" WA_NODE_MAC_ONLY="$REAL_MAC"
  for e in $envspec; do export "$e"; done   # várias VAR=valor separadas por espaço ($T não tem espaço)
  CLS="$CLS_REAL"
  eval "${MUTANT_PRE:-:}"   # recria o estado que o caso precisa (um cache de irmãs escrito à mão): o original reescreve o cache ao recalcular, e o mutante leria o que o original gravou
  if ! check "$json" "$rc" "$rx"; then
    bad "mutante $name VAZIO: o classificador ORIGINAL já reprova o caso designado (rc=$RC, esperado $rc; saída: $(printf '%s' "$OUT" | cut -c1-200))"
  else
    CLS="$M"
    eval "${MUTANT_PRE:-:}"
    if check "$json" "$rc" "$rx"; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"
    elif printf '%s' "$OUT" | grep -q -E 'nao-consegui:(filtro|mac-only)-ilegivel' && ! printf '%s' "$rx" | grep -q 'ilegivel'; then
      bad "mutante $name morreu PELO AMBIENTE, não pela mutação (rc=$RC; saída: $(printf '%s' "$OUT" | cut -c1-200))"
    else ok "mutante $name morreu"; fi
    CLS="$CLS_REAL"
  fi
  unset WA_NODE_FILTER WA_NODE_MAC_ONLY; for e in $envspec; do unset "${e%%=*}"; done
  export WA_NODE_MIRROR="$T/espelho-ausente"   # o padrão da bateria (um envspec pode ter trocado e desarmado)
  export WA_NODE_REPO="$T/wa-repo-ausente"     # idem o repo do WA (a regra 6 só vê o repo de mentira nos casos que o pedem por envspec)
  export WA_NODE_CACHE="$T/cache"              # idem o cache das irmãs (um envspec que o troca o desarmou; sem isto o mutante gravaria no .gc/ de verdade)
}
mutant_pre() { MUTANT_PRE="$1"; shift; mutant "$@"; MUTANT_PRE=""; }   # mutant_pre '<comando>' <args do mutant>: o comando roda antes de CADA execução (original e mutante)
mutant sem-node-mini     '"node:mini" in labels'                       'False'                                  "$(labels "$GOOD" '["node:mini"]')" 10 'etiqueta-node:mini'
mutant sem-epic          'b.get("issue_type") == "epic"'               'False'                                  "$(field "$GOOD" issue_type '"epic"')" 10 '"epic"'
mutant sem-pii           'if has_pii(json.dumps'                       'if False and has_pii(json.dumps'        "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" 10 'dado-no-texto'
mutant pii-sem-cauda     'len(set(d[-8:])) > 3'                        'len(set(d[-8:])) >= 0'                  "$(DESC 'lib/x.py tests/test_x.py +55 31 99999-9999')" 0 '"verdict": "node"'
mutant filtro-ignorado   'if p not in sent and p not in via_mirror:'   'if False:'                              "$WITHDB" 10 'caminho-fora-do-filtro'
mutant mac-ignorado      'hard.append("so-no-mac:" + p)' 'pass'                    "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac' "WA_NODE_MAC_ONLY=$T/macs.txt"
# o canário tem DUAS metades (o de código TEM de sair, os de segredo NÃO): um mutante por metade e um para as duas; cada um com o rsync que só ELE separa do original
mutant sem-canario       'if any(c not in sent for c in ok_canary) or any(c in sent for c in no_canary):' 'if False:'          "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-codigo 'if any(c not in sent for c in ok_canary) or any(' 'if False or any('                          "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-segredo 'or any(c in sent for c in no_canary):'    'or False:'                              "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-tudo"
mutant rc-ignorado       'if r.returncode != 0:'                       'if False:'                              "$GOOD" 11 'rsync-rc-23' "WA_NODE_RSYNC=$T/rs-parcial"
mutant sem-moles         'if soft and not override:'                   'if False:'                              "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
mutant label-ignorada    'override = "node:ok" in labels'              'override = False'                       "$(labels "$NOPROOF" '["node:ok"]')" 0 'label'
mutant prova-frouxa      'if tests and code:'                          'if tests or True:'                      "$NOPROOF" 11 'sem-prova'
mutant unreadable-node   'v, why, paths, tests, info = "unknown", ["nao-consegui:"' 'v, why, paths, tests, info = "node", ["nao-consegui:"' 'isto nao e json' 11 'json-ilegivel'
# caminho fora do formato: as checagens explícitas ('/' inicial, '', '.', '..') são SUBSUMIDAS por SAFE_SEG (que recusa segmento vazio ou começado em ponto) — tirar só elas é mutante equivalente e não se lista.
# Mata-se a condição inteira e, separado, só o SAFE_SEG (o caso de letra não-ASCII é o que só ele segura).
mutant caminho-solto     'if p.startswith("/") or any(s in ("", ".", "..") for s in segs) or not all(SAFE_SEG.match(s) for s in segs):' 'if False:' "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
mutant sem-safe-seg      ' or not all(SAFE_SEG.match(s) for s in segs):' ':'                                  "$(DESC 'lib/x.py tests/test_x.py e lib/ação.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
mutant sem-teto-texto    'if len(text) > MAX_TEXT:'                    'if False:'                              "$(printf '{"id":"wa-b","title":"t","description":"lib/a.py tests/test_a.py %s"}' "$BIG")" 11 'texto-grande'
mutant labels-frouxas    'if not isinstance(lab, list) or not all(isinstance(x, str) for x in lab):' 'if False:' "$(labels "$GOOD" '"node:ok"')" 11 'labels-ilegiveis'
mutant abs-vira-mole     'norm(text.replace(REPO_ABS, ""))'            'norm(text)'                             "$(DESC 'ver /Users/athos/gt/whatsapp_automation/lib/foo.py e tests/test_foo.py')" 0 '"verdict": "node"'
mutant sem-catch-all    'except Exception as e:'                      'except ZeroDivisionError as e:'         "$("$PY" -I -c 'print("["*200000)')" 11 'erro-inesperado'
mutant teto-frouxo       'if len(out) >= MAX_PATHS:'                   'if len(out) > MAX_PATHS:'               "$(DESC "${P39}lib/m40.py tests/test_x.py")" 10 'caminhos-demais'
mutant sufixo-vira-arquivo '(?![\w\-]|\.\w)'                           '(?![\w])'                               "$(DESC 'lib/x.py.bak e tests/test_x.py')" 11 '"paths": \["tests/test_x\.py"\]'
mutant sem-maiuscula     ', re.IGNORECASE)'                            ')'                                      "$(DESC 'lib/x.py tests/test_x.py e DATA/Leads.CSV')" 10 'caminho-fora-do-filtro:DATA/Leads\.CSV'   # 1ª ocorrência = PATH_RE (HOME_RE vem depois)
mutant sem-sqlite3       '|db|sqlite3?|xlsx|'                          '|db|sqlite|xlsx|'                       "$(DESC 'lib/x.py tests/test_x.py e data/x.sqlite3')" 10 'caminho-fora-do-filtro:data/x\.sqlite3'
mutant sem-home          'if HOME_RE.search(text):'                    'if False:'                              "$(DESC 'lib/x.py tests/test_x.py e ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
mutant mac-vazio-vale    'if not globs:'                               'if False:'                              "$GOOD" 11 'mac-only-vazio' "WA_NODE_MAC_ONLY=$T/macs-vazio.txt"
# espelho git: cada mutante troca UMA linha da regra nova e o caso designado reprova; o ambiente do caso (stub do espelho) vem em "VAR=valor"
mutant espelho-sem-negacoes 'open_sent = sent_by_filter(cands, only_denies=True)' 'open_sent = set(cands)' "$(DESC "${DOCS}shared/notas.md")" 10 'caminho-fora-do-filtro:shared/notas\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-sem-varredura 'denied = mirror_denied(mirror_rules(), ok)' 'denied = set()' "$(DESC "${DOCS}docs/sinalizado.md")" 10 'caminho-fora-do-filtro:docs/sinalizado\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-vira-teste 'elif p in via_mirror:' 'elif False:' "$(DESC 'ajustar lib/x.py conforme docs/tests/plan.md')" 11 'sem-prova-de-codigo-e-teste.*via-espelho:docs/tests/plan\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-ext-solta 'MIRROR_TEXT_EXT = ("md",)' 'MIRROR_TEXT_EXT = ("md", "json", "txt")' "$(DESC "${DOCS}docs/auto_response/ab_results/x.json")" 10 'caminho-fora-do-filtro:docs/auto_response/ab_results/x\.json' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-falha-vira-chega 'return [], ["espelho-ilegivel:" + str(e)]' 'return cands, ["espelho-ilegivel:" + str(e)]' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-sem-resposta'
mutant espelho-rc-ignorado 'raise Unreadable("espelho-rc-%d" % r.returncode)' 'pass' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-rc-75' "WA_NODE_MIRROR=$T/mirror-75"
mutant espelho-sem-raiz 'lines[0] != "/*" or ' '' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-formato' "WA_NODE_MIRROR=$T/mirror-sem-raiz"
mutant espelho-linha-torta 'any(not l.startswith("!") or len(l) < 2 for l in lines[1:])' 'False' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-formato' "WA_NODE_MIRROR=$T/mirror-torta"
mutant espelho-poucas-regras 'len(rules) < MIRROR_MIN_RULES or ' '' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-filtro-cortado' "WA_NODE_MIRROR=$T/mirror-curto"
mutant espelho-sem-familias 'or any(c not in rules for c in ("*.csv", "*.db", "*.parquet", ".env", "*.duckdb*"))' '' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-filtro-cortado' "WA_NODE_MIRROR=$T/mirror-sem-parquet"
mutant espelho-sem-canario-dado 'any(c not in denied for c in CANARY_MIRROR_NO) or ' '' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-canario-errado' "WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-mudo"
mutant espelho-sem-canario-doc ' or CANARY_OK in denied or CANARY_DOC in denied' '' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-canario-errado' "WA_NODE_MIRROR=$T/mirror-nega-md"
mutant espelho-git-rc-ignorado 'if r.returncode not in (0, 1):' 'if False:' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:espelho-git-rc-128' "WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-quebrado"
mutant so-neg-sem-canario-pasta 'no_canary += list(CANARY_OPEN_NO)' 'pass' "$(DESC "${DOCS}docs/runbooks/guia.md")" 10 'espelho-ilegivel:canario-errado' "WA_NODE_MIRROR=$T/mirror-ok WA_NODE_RSYNC=$T/rs-so-neg-vaza"
# teste derivado (regra 6): um mutante por linha da regra; o repo de mentira e o espelho de mentira vêm por envspec (o padrão da bateria é repo e espelho AUSENTES)
DV="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok"
D_FOO=$(DESC 'Corrigir lib/foo_parser.py quando a entrada vem vazia.')
mutant derivado-sem-freio       'if blocked:'                          'if False:'                                  "$(DESC 'Corrigir lib/foo_parser.py; o lead some da lista')" 10 'freio-derivado:dado-de-lead' "$DV"
mutant derivado-freio-sem-lead  'DERIVED_BLOCK_INFO = ("dado-de-lead", "envio-whatsapp")' 'DERIVED_BLOCK_INFO = ("envio-whatsapp",)' "$(DESC 'Corrigir lib/foo_parser.py; o lead some da lista')" 10 'freio-derivado:dado-de-lead' "$DV"
mutant derivado-freio-sem-envio 'DERIVED_BLOCK_INFO = ("dado-de-lead", "envio-whatsapp")' 'DERIVED_BLOCK_INFO = ("dado-de-lead",)' "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 'freio-derivado:envio-whatsapp' "$DV"
mutant derivado-basis-text      'basis = "derivado" if any(w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:")) for w in why) else "text"' 'basis = "text"' "$D_FOO" 0 '"basis": "derivado"' "$DV"
mutant derivado-sem-maior       ' and not any(rest == m or rest.startswith(m + "_") for m in longer))' ')' "$(DESC 'ajustar lib/bar_service.py')" 0 'prova-teste-derivado:1-teste\(s\)' "$DV"
mutant derivado-sem-generico    ' and s not in GENERIC_STEMS'          ''                                           "$(DESC 'ajustar lib/utils.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-minimo      ' and len(s) >= MIN_STEM'              ''                                           "$(DESC 'ajustar lib/abcd.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-formato     'return s if STEM_RE.match(s) and'     'return s if True and'                       "$(DESC 'ajustar lib/dash-mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-css-ganha-teste ' and p.rsplit(".", 1)[-1] in DERIVE_EXT else ""' ' else ""'               "$(DESC 'ajustar lib/css_mod.css')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-rastreado   's = module_stem(p) if p in present and' 's = module_stem(p) if True and'  "$(DESC 'criar lib/novo_modulo.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-nome-solto      '(rest == s or rest.startswith(s + "_"))' '(s in rest)'                             "$(DESC 'ajustar lib/inner_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-sublinhado  'or rest.startswith(s + "_"))'         'or rest.startswith(s))'                     "$(DESC 'ajustar lib/boundary.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-ext-solta       '(?:py|js|cjs|mjs)$")'                 '(?:py|js|cjs|mjs|json)$")'                  "$(DESC 'ajustar lib/ext_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-espelho     'keep = [t for t in keep if t not in denied]' 'keep = keep'                           "$(DESC 'ajustar lib/flag_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-mac-only    ' and not any(fnmatch.fnmatchcase(t, g) for g in globs)]' ']'                       "$(DESC 'ajustar lib/mac_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV WA_NODE_MAC_ONLY=$T/macs-derivado.txt"
mutant derivado-sem-rsync       'keep = [t for t in allc if t in sent and' 'keep = [t for t in allc if True and'     "$(DESC 'ajustar lib/tok_mod.py')" 11 'sem-prova-de-codigo-e-teste' "WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-sem-token"
mutant derivado-sem-conteudo    'ok = [t for t in ts if t in hits]'    'ok = list(ts)'                              "$(DESC 'ajustar lib/silent_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-sem-palavra     '"grep", "-l", "-w", "-F"'             '"grep", "-l", "-F"'                         "$(DESC 'ajustar lib/subs_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-ref-head        'os.environ.get("WA_NODE_REPO_REF", "origin/main")' 'os.environ.get("WA_NODE_REPO_REF", "HEAD")' "$(DESC 'ajustar lib/late_mod.py')" 11 'sem-prova-de-codigo-e-teste' "$DV"
mutant derivado-vazio-vale      'raise Unreadable("repo-vazio")'       'pass'                                       "$D_FOO" 11 'teste-derivado-ilegivel:repo-vazio' "WA_NODE_REPO=$T/wa-repo-vazio WA_NODE_MIRROR=$T/mirror-ok"
mutant derivado-rc-ignorado     'raise Unreadable("repo-git-rc-%d" % r.returncode)' 'pass'                          "$D_FOO" 11 'teste-derivado-ilegivel:repo-git-rc-128' "$DV WA_NODE_REPO_REF=origin/zz"
mutant derivado-ref-livre       'if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./\-]*", REPO_REF):' 'if False:'       "$D_FOO" 11 'teste-derivado-ilegivel:repo-ref-invalida' "$DV WA_NODE_REPO_REF=--oops"
mutant derivado-grep-rc         'raise Unreadable("repo-grep-rc-%d" % r.returncode)' 'pass'                         "$D_FOO" 11 'teste-derivado-ilegivel:repo-grep-rc-2' "$DV WA_NODE_GIT=$T/git-grep-quebra"
mutant derivado-grep-mudo       'if r.returncode == 0 and not hits:'   'if False:'                                  "$D_FOO" 11 'teste-derivado-ilegivel:repo-grep-ilegivel' "$DV WA_NODE_GIT=$T/git-grep-mudo"
mutant derivado-falha-vira-vazio 'note = ["teste-derivado-ilegivel:" + str(e)]' 'note = []'                         "$D_FOO" 11 'teste-derivado-ilegivel:espelho-rc-75' "WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-75"
mutant derivado-sem-pares       'dinfo = pairs[:6] + ('                'dinfo = [] and ('                           "$D_FOO" 0 'teste-derivado:lib/foo_parser\.py=tests/test_foo_parser\.py' "$DV"
mutant derivado-sem-teto-pares  'dinfo = pairs[:6] + ('                'dinfo = pairs + ('                          "$(DESC 'ajustar lib/many_mod.py')" 0 'test_many_mod_6\.py", "teste-derivado-mais:1"\]\}$' "$DV"
mutant derivado-sem-teto-modulo 'mine[:MAX_DERIVED_PER_STEM]'          'mine'                                       "$(DESC 'ajustar lib/huge_mod.py')" 0 'prova-teste-derivado:25-teste' "$DV"
mutant derivado-sem-teto-total  ')[:MAX_DERIVED_TESTS]'                ')'                                          "$(DESC 'ajustar lib/cap_a.py lib/cap_b.py lib/cap_c.py lib/cap_d.py lib/cap_e.py')" 0 'prova-teste-derivado:100-teste' "$DV"
# nome solto (ga-2hd02v.3.17): um mutante por linha da regra
SV="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok"
S_HTML=$(DESC "lib/x.py e $SOLTO_TESTE: ajustar loose_page.html")
mutant solto-arvore-nao-troca    'swap[p] = hits[0]'                   'pass'                                       "$S_HTML" 0 'caminho-solto:loose_page\.html=templates/loose_page\.html' "$SV"
mutant solto-citado-nao-troca    'swap[p] = cited[0]'                  'pass'                                       "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html (dup_page.html)")" 0 'caminho-solto:dup_page\.html=templates/dup_page\.html' "$SV"
mutant solto-citado-ignora       'cited = sorted(set(q for q in foldered if q.rsplit("/", 1)[-1] == p))' 'cited = []' "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html (dup_page.html)")" 0 'caminho-solto:dup_page\.html=templates/dup_page\.html' "$SV"
mutant solto-dois-citados-escolhe 'if len(cited) == 1 and ok and p not in tree:' 'if len(cited) >= 1 and ok and p not in tree:' "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html e daemons/templates/dup_page.html (dup_page.html)")" 10 'caminho-fora-do-filtro:dup_page\.html' "$SV"
mutant solto-ambiguo-escolhe     'if len(hits) == 1 and'               'if len(hits) >= 1 and'                       "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar dup_page.html")" 10 'caminho-fora-do-filtro:dup_page\.html' "$SV"
mutant solto-sem-formato-seguro  ' and all(SAFE_SEG.match(sg) for sg in hits[0].split("/")):' ':'                       "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar pagina_estranha.html")" 10 'caminho-fora-do-filtro:pagina_estranha\.html' "$SV"
mutant solto-sem-filtro          'sent = set(sent) | sent_by_filter(new)' 'sent = set(sent) | set(new)'        "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar notas_solto.md")" 10 'caminho-fora-do-filtro:shared/notas_solto\.md' "$SV"
mutant solto-dado-tambem         'RESOLVE_EXT = CODE_EXT + ("html", "md")' 'RESOLVE_EXT = CODE_EXT + ("html", "md", "json")' "$(DESC "lib/x.py e $SOLTO_TESTE: ler solto_dado.json")" 10 'caminho-fora-do-filtro:solto_dado\.json' "$SV"
mutant solto-codigo-nao-resolve  ' and (p not in sent or p.rsplit(".", 1)[-1].lower() in CODE_EXT)]' ' and p not in sent]'         "$(DESC 'ajustar solto_run.sh')" 0 'caminho-solto:solto_run\.sh=scripts/solto_run\.sh' "$SV"
mutant solto-falha-vira-vazio    'note = ["caminho-solto-ilegivel:" + str(e)]' 'note = []'                       "$S_HTML" 10 'caminho-solto-ilegivel:repo-git-rc-128'
# a regra (1) (o citado com pasta) só vale com a árvore LIDA e sem arquivo da raiz com o nome: cada mutante volta a uma metade da regra antiga
mutant solto-citado-ignora-a-raiz 'if len(cited) == 1 and ok and p not in tree:' 'if len(cited) == 1 and ok:'          "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dupr_page.html (dupr_page.html)")" 10 'caminho-fora-do-filtro:dupr_page\.html' "$SV"
mutant solto-citado-sem-arvore    'if len(cited) == 1 and ok and p not in tree:' 'if len(cited) == 1 and p not in tree:' "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/loose_page.html (loose_page.html)")" 10 'caminho-fora-do-filtro:loose_page\.html.*caminho-solto-ilegivel:repo-git-rc-128'
mutant solto-citado-sem-arvore-nem-raiz 'if len(cited) == 1 and ok and p not in tree:' 'if len(cited) == 1:'                "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/loose_page.html (loose_page.html)")" 10 'caminho-fora-do-filtro:loose_page\.html.*caminho-solto-ilegivel:repo-git-rc-128'
mutant solto-arvore-lida-nao-marca-ok 'tree, ok = set(repo_tree()), True' 'tree, ok = set(repo_tree()), False'  "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar templates/dup_page.html (dup_page.html)")" 0 'caminho-solto:dup_page\.html=templates/dup_page\.html' "$SV"
# caminho derivado (ga-2hd02v.3.20, regra 7): um mutante por linha da regra; o repo/espelho de mentira vêm por envspec e o cache é PROIBIDO (/dev/null/...) para o original e o mutante recalcularem do git
R7="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_CACHE=/dev/null/sem-cache"
FD=$(DESC 'revisar ficha_donos quando a entrada vem vazia')
mutant caminho-sem-hifen        '.lower().replace("-", "_")'           '.lower()'                                   "$(DESC 'revisar o form-fill quando o campo vem vazio')" 0 'caminho-derivado:nome:form_fill' "$R7"
mutant caminho-sem-minuscula    '.lower().replace("-", "_")'           '.replace("-", "_")'                         "$(DESC 'revisar a Ficha_Donos quando vem vazia')" 0 'caminho-derivado:nome:ficha_donos' "$R7"
mutant caminho-nome-curto       's = valid_stem(m.group(1).lower().replace("-", "_"))' 's = m.group(1).lower().replace("-", "_")' "$(DESC 'revisar db_x quando vem vazio')" 11 "$SEMNOTA" "$R7"
mutant caminho-nome-com-pasta   '(?<![\w/.\-~$])([A-Za-z]'             '(?<![\w.\-~$])([A-Za-z]'                    "$(DESC 'ver a pasta docs/ficha_donos quando vem vazia')" 11 "$SEMNOTA" "$R7"
mutant caminho-nome-com-ext     '[A-Za-z0-9]+)+)(?![\w/]|\.\w)'        '[A-Za-z0-9]+)+)(?![\w/])'                   "$(DESC 'ver ficha_donos.xyz quando vem vazio')" 11 "$SEMNOTA" "$R7"
mutant caminho-nome-com-barra   '[A-Za-z0-9]+)+)(?![\w/]|\.\w)'        '[A-Za-z0-9]+)+)(?![\w]|\.\w)'               "$(DESC 'ver ficha_donos/algo quando vem vazio')" 11 "$SEMNOTA" "$R7"
mutant caminho-ambiguo          'if len(fs) > MAX_FILES_PER_NAME:'     'if False:'                                  "$(DESC 'revisar ambig_mod quando vem vazio')" 11 'caminho-derivado-ambiguo:ambig_mod=4' "$R7"
mutant caminho-sem-teto         'if len(out) > MAX_DERIVED_CODE:'      'if False:'                                  "$(DESC 'revisar limcap_01 limcap_02 limcap_03 limcap_04 limcap_05 limcap_06 limcap_07 limcap_08 limcap_09 limcap_10 limcap_11 limcap_12')" 11 'caminho-derivado-demais:12' "$R7"
mutant caminho-sem-teto-irmas   'if len(out) > MAX_DERIVED_CODE:'      'if False:'                                  "$(DESCI wa-par4.2 'corrigir o caso de borda')" 11 'caminho-derivado-demais:11' "$R7"
mutant caminho-sem-filtro       'if p not in dsent:'                   'if False:'                                  "$(DESC 'revisar fora_mod quando vem vazio')" 10 'caminho-derivado-fora-do-filtro:shared/fora_mod' "$R7"
mutant caminho-sem-mac-only     'hard.append("caminho-derivado-so-no-mac:" + p)' 'pass'                             "$(DESC 'revisar mac_code_mod quando vem vazio')" 10 'caminho-derivado-so-no-mac:lib/mac_code_mod' "$R7 WA_NODE_MAC_ONLY=$T/macs-derivado7.txt"
mutant caminho-citado-vale      'if tests:   # a bead cita o teste'    'if False:   # a bead cita o teste'         "$(DESC 'tests/test_x.py cobre sem_teste_mod quando vem vazio')" 0 'prova-caminho-derivado' "$R7"
mutant caminho-teste-de-mentira 'found = derived_tests(dpaths, globs)' 'found = dict((p, ["tests/x.py"]) for p in dpaths)' "$(DESC 'revisar sem_teste_mod quando vem vazio')" 11 'sem-prova-de-codigo-e-teste' "$R7"
mutant caminho-falha-vira-vazio 'extra.append("caminho-derivado-ilegivel:" + str(e))' 'pass'                          "$FD" 11 'caminho-derivado-ilegivel:repo-git-rc-128' "WA_NODE_REPO=$T/wa-repo-ausente WA_NODE_MIRROR=$T/mirror-ok WA_NODE_CACHE=/dev/null/sem-cache"
mutant caminho-com-codigo-citado 'if not code:'                         'if True:'                                   "$(DESC 'ajustar lib/sem_teste_mod.py e a ficha_donos')" 11 "$SEMNOTA" "$R7"
mutant caminho-basis-text       'w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:"))' 'w.startswith("prova-teste-derivado:")' "$FD" 0 '"basis": "derivado"' "$R7"
mutant caminho-sem-freio        'if blocked:'                          'if False:'                                  "$(DESC 'revisar ficha_donos: o lead some da lista')" 10 'freio-derivado:dado-de-lead.*caminho-derivado:nome:ficha_donos' "$R7"
mutant caminho-custo-zero       '"derivacao_ms": COST["derivacao_ms"]' '"derivacao_ms": 0'                          "$FD" 0 '"derivacao_ms": [1-9][0-9]*' "$R7"
mutant irmas-sem-campo-parent   'if isinstance(p, str) and PARENT_RE.match(p):' 'if False:'                         "$(printf '{"id":"wa-zzz9","parent":"wa-par1","title":"t","description":"corrigir o caso de borda"}')" 0 'caminho-derivado:irmas=lib/irma_mod' "$R7"
mutant irmas-id-inteiro         'p = i.rsplit(".", 1)[0]'              'p = i'                                      "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 'caminho-derivado:irmas=lib/irma_mod' "$R7"
mutant irmas-sem-arvore         'if f in present:'                     'if True:'                                   "$(DESCI wa-par3.2 'corrigir o caso de borda')" 11 "$SEMNOTA" "$R7"
mutant irmas-rc-ignorado        'raise Unreadable("irmas-git-rc-%d" % r.returncode)' 'pass'                         "$(DESCI wa-par1.3 'corrigir o caso de borda')" 11 'caminho-derivado-ilegivel:irmas-git-rc-2' "$R7 WA_NODE_GIT=$T/git-log-quebra"
mutant irmas-sem-resposta       'raise Unreadable("irmas-git-sem-resposta")' 'return []'                            "$(DESCI wa-par1.3 'corrigir o caso de borda')" 11 'caminho-derivado-ilegivel:irmas-git-sem-resposta' "$R7 WA_NODE_GIT=$T/git-log-lento WA_NODE_SIBLING_TIMEOUT=1"
mutant irmas-nao-diz-que-nao-gravou 'COST["cache"] = "miss" if cache_put(parent, names) else "nao-gravou"' 'COST["cache"] = "miss"' "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 '"cache": "nao-gravou"' "$R7"
mutant irmas-sem-janela         '"--since=%d.days.ago" % SIBLING_DAYS, '                 ''                    "$(DESCI wa-par5.2 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$R7"
mutant irmas-janela-sem-piso    'min(3650, max(1, int(os.environ.get("WA_NODE_SIBLING_DAYS", "45"))))' 'min(3650, int(os.environ.get("WA_NODE_SIBLING_DAYS", "45")))' "$(DESCI wa-par1.3 'corrigir o caso de borda')" 0 "$N_OK" "$R7 WA_NODE_SIBLING_DAYS=0"
mutant irmas-janela-sem-teto    'min(3650, max(1, int(os.environ.get("WA_NODE_SIBLING_DAYS", "45"))))' 'max(1, int(os.environ.get("WA_NODE_SIBLING_DAYS", "45")))' "$(DESCI wa-par5.2 'corrigir o caso de borda')" 0 "$N_OK.*caminho-derivado:irmas=lib/velha_mod\\.py" "$R7 WA_NODE_SIBLING_DAYS=99999"
# cache: o estado é escrito à mão antes de cada execução (o original, ao recalcular, regrava o cache e o mutante leria o que ele gravou)
CM="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_CACHE=$T/cache-m"
mutant_pre "seedc $T/cache-m wa-parc 60 '[\"lib/ficha_donos.py\"]'" cache-ignorado '-60 <= age <= SIBLING_TTL' 'False' "$(DESCI wa-parc.1 'corrigir o caso de borda')" 0 '"cache": "hit"' "$CM"
mutant_pre "seedc $T/cache-m wa-parv $((7*3600)) '[\"lib/ficha_donos.py\"]'" cache-vencido-vale '-60 <= age <= SIBLING_TTL' '-60 <= age' "$(DESCI wa-parv.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$CM"
mutant_pre "seedc $T/cache-m wa-parw 60 '[\"lib/ficha_donos.py\"]' wa-outro" cache-outro-pai 'd["parent"] == parent and ' '' "$(DESCI wa-parw.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$CM"
# o resíduo no TMPDIR: o mutante que não apaga a árvore tem de deixar item para trás (senão o teste de "sem resíduo" passaria mesmo sem a limpeza)
if mk_mutant sem-limpeza 'shutil.rmtree(root, ignore_errors=True)' 'pass'; then
  left=$(tmp_residue "$T/mut-sem-limpeza.py")
  [ "${left:-0}" -ge 1 ] && ok "mutante sem-limpeza morreu" || bad "mutante sem-limpeza SOBREVIVEU (sem apagar a árvore o TMPDIR ficou com $left item(ns))"
else bad "mutante sem-limpeza: o trecho original não existe (o classificador mudou? atualize o mutante)"; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
