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
  if ! check "$json" "$rc" "$rx"; then
    bad "mutante $name VAZIO: o classificador ORIGINAL já reprova o caso designado (rc=$RC, esperado $rc; saída: $(printf '%s' "$OUT" | cut -c1-200))"
  else
    CLS="$M"
    if check "$json" "$rc" "$rx"; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"
    elif printf '%s' "$OUT" | grep -q -E 'nao-consegui:(filtro|mac-only)-ilegivel' && ! printf '%s' "$rx" | grep -q 'ilegivel'; then
      bad "mutante $name morreu PELO AMBIENTE, não pela mutação (rc=$RC; saída: $(printf '%s' "$OUT" | cut -c1-200))"
    else ok "mutante $name morreu"; fi
    CLS="$CLS_REAL"
  fi
  unset WA_NODE_FILTER WA_NODE_MAC_ONLY; for e in $envspec; do unset "${e%%=*}"; done
  export WA_NODE_MIRROR="$T/espelho-ausente"   # o padrão da bateria (um envspec pode ter trocado e desarmado)
}
mutant sem-node-mini     '"node:mini" in labels'                       'False'                                  "$(labels "$GOOD" '["node:mini"]')" 10 'etiqueta-node:mini'
mutant sem-epic          'b.get("issue_type") == "epic"'               'False'                                  "$(field "$GOOD" issue_type '"epic"')" 10 '"epic"'
mutant sem-pii           'if has_pii(json.dumps'                       'if False and has_pii(json.dumps'        "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" 10 'dado-no-texto'
mutant pii-sem-cauda     'len(set(d[-8:])) > 3'                        'len(set(d[-8:])) >= 0'                  "$(DESC 'lib/x.py tests/test_x.py +55 31 99999-9999')" 0 '"verdict": "node"'
mutant filtro-ignorado   'if p not in sent and p not in via_mirror:'   'if False:'                              "$WITHDB" 10 'caminho-fora-do-filtro'
mutant mac-ignorado      'elif any(fnmatch.fnmatchcase(p, g) for g in globs):' 'elif False:'                    "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac' "WA_NODE_MAC_ONLY=$T/macs.txt"
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
# o resíduo no TMPDIR: o mutante que não apaga a árvore tem de deixar item para trás (senão o teste de "sem resíduo" passaria mesmo sem a limpeza)
if mk_mutant sem-limpeza 'shutil.rmtree(root, ignore_errors=True)' 'pass'; then
  left=$(tmp_residue "$T/mut-sem-limpeza.py")
  [ "${left:-0}" -ge 1 ] && ok "mutante sem-limpeza morreu" || bad "mutante sem-limpeza SOBREVIVEU (sem apagar a árvore o TMPDIR ficou com $left item(ns))"
else bad "mutante sem-limpeza: o trecho original não existe (o classificador mudou? atualize o mutante)"; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
