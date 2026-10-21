#!/usr/bin/env bash
# ps-node-classify.selftest.sh — hermético: o filtro e o rsync são os REAIS (o filtro é a fronteira de dados do nó), a lista mac-only e os rsync de falha são stubs numa pasta temporária. (ga-2hd02v.4)
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
# COMO RODAR: bash scripts/ps-node-classify.selftest.sh   (macOS /bin/bash 3.2 e Linux). Pesado o bastante para ir ao nó: scripts/mbp-run.sh --repo hq scripts/ps-node-classify.selftest.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLS_REAL="$HERE/ps-node-classify.py"
PII="$HERE/hetzner-pii-scan.py"
REAL_FILTER="$HERE/hetzner-rsync-filter.ps.txt"; REAL_MAC="$HERE/hetzner-mac-only.ps.txt"   # um classificador que mora fora de scripts/ (os mutantes) acha o filtro por env, não por HERE
T=$(mktemp -d "${TMPDIR:-/tmp}/ps-node-cls.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
PY=${PS_NODE_SELFTEST_PY:-python3}

CLS="$CLS_REAL"; OUT=""; RC=0
run() { OUT=$(printf '%s' "$1" | "$PY" -I "$CLS" 2>/dev/null); RC=$?; }
# check <json> <rc> <regex da saída> -> 0 se o rc é o esperado e a saída casa; sem imprimir (os mutantes usam o mesmo)
check() { run "$1"; [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -q -E -e "$3"; }
expect() { # expect <rótulo> <json> <rc> <regex>
  if check "$2" "$3" "$4"; then ok "$1"; else bad "$1 (rc=$RC, esperado $3; saída: $(printf '%s' "$OUT" | cut -c1-230))"; fi
}
labels() { printf '%s' "${1%\}},\"labels\":$2}"; }
field() { printf '%s' "${1%\}},\"$2\":$3}"; }

GOOD='{"id":"ps-t1","title":"parse_bar devolve None para entrada vazia","description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}'
NOPROOF='{"id":"ps-t2","title":"melhorar mensagem de erro","description":"A mensagem de erro do importador esta confusa."}'
WITHDB='{"id":"ps-t3","title":"lê o banco","description":"scripts/foo.py lê queue.db; teste em tests/test_foo.py"}'
DESC() { printf '{"id":"ps-t9","title":"t","description":"%s"}' "$1"; }

# ---- node
expect "node: código + teste citados, nada que bloqueie" "$GOOD" 0 '"verdict": "node", "basis": "text".*prova-no-texto:1-teste\(s\)\+1-codigo'
expect "node: etiqueta node:ok dispensa a prova no texto" "$(labels "$NOPROOF" '["node:ok"]')" 0 '"verdict": "node", "basis": "label".*etiqueta-node:ok'
expect "node: id de pytest (::) e linha (:123) não atrapalham o caminho" "$(DESC 'tests/test_a.py::test_x quebra; ver lib/a.py:123')" 0 '"verdict": "node"'
expect "node: o caminho absoluto do repo é normalizado para o relativo" "$(DESC 'ver /Users/athos/gt/property_scrapers/lib/foo.py e tests/test_foo.py')" 0 '"paths": \["lib/foo.py", "tests/test_foo.py"\]'
expect "mini: outro caminho /Users/... (não o do repo) continua sendo host Mac" "$(DESC 'lib/x.py e tests/test_x.py; o diretorio /Users/athos/notas')" 10 'moles:host-mac'
expect "node: palavras do produto (deploy, coleta, anúncio, tela) só informam" "$(DESC 'lib/x.py trata anuncio na coleta do deploy da tela; tests/test_x.py')" 0 '"verdict": "node".*"info": \["producao", "raspagem", "dado-de-anuncio", "tela-ao-vivo"\]'
expect "node: telefone sintético (cauda repetida) não conta como dado" "$(DESC 'lib/x.py e tests/test_x.py usam +55 31 99999-9999 como exemplo')" 0 '"verdict": "node"'
# ---- mini
expect "mini: etiqueta node:mini vence node:ok" "$(labels "$GOOD" '["node:ok","node:mini"]')" 10 'etiqueta-node:mini'
expect "mini: epic" "$(field "$GOOD" issue_type '"epic"')" 10 '"reasons": \["epic"\]'
expect "mini: bead devolvida pelo nó (athos.node_recusa) fica no mini, mesmo com node:ok" "$(labels "$(field "$GOOD" metadata '{"athos.node_recusa":"precisa do banco"}')" '["node:ok"]')" 10 'recusada-pelo-no'
expect "node: athos.node_recusa vazio não conta como devolvida" "$(field "$GOOD" metadata '{"athos.node_recusa":"  "}')" 0 '"verdict": "node"'
expect "node: metadata sem a chave não conta como devolvida" "$(field "$GOOD" metadata '{"outra":"x"}')" 0 '"verdict": "node"'
expect "unknown: metadata que não é objeto (ilegível) NÃO vira node" "$(field "$GOOD" metadata '"texto"')" 11 'metadata-ilegivel'
expect "mini: banco .db citado (o filtro segura)" "$WITHDB" 10 'caminho-fora-do-filtro:queue\.db'
expect "mini: pasta data/ citada (o filtro segura mesmo sendo .py)" "$(DESC 'lib/x.py usa data/helper.py; tests/test_x.py')" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "mini: credentials*.json citado" "$(DESC 'lib/x.py lê config/credentials_prod.json; tests/test_x.py')" 10 'caminho-fora-do-filtro:config/credentials_prod\.json'
expect "node: doc .md está no filtro do PS (o nó o tem), mas não é código nem teste" "$(DESC 'lib/x.py conforme docs/guia.md; tests/test_x.py')" 0 '"verdict": "node".*"paths": \["lib/x.py", "docs/guia.md", "tests/test_x.py"\]'
expect "node: só o doc citado NÃO é prova (doc + teste, sem código)" "$(DESC 'conforme docs/guia.md e tests/test_x.py')" 11 'sem-prova'
expect "mini: yaml de notebook fora do filtro" "$(DESC 'lib/x.py e notebooks/owner_consolidator/baseline.yaml; tests/test_x.py')" 10 'caminho-fora-do-filtro:notebooks/owner_consolidator/baseline\.yaml'
expect "mini: config/seen_properties.json é estado de execução (fora do filtro)" "$(DESC 'lib/x.py zera config/seen_properties.json; tests/test_x.py')" 10 'caminho-fora-do-filtro:config/seen_properties\.json'
expect "mini: pasta crew/ (worktree de outro agente) fora do filtro" "$(DESC 'veja crew/worker/lib/x.py e tests/test_x.py')" 10 'caminho-fora-do-filtro:crew/worker/lib/x\.py'
expect "mini: shared/ (dado de execução) fora do filtro" "$(DESC 'lib/x.py le shared/snap/y.json; tests/test_x.py')" 10 'caminho-fora-do-filtro:shared/snap/y\.json'
expect "mini: telefone real no texto (duro)" "$(DESC 'lib/x.py tests/test_x.py cliente (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "mini: CPF dentro da metadata (duro)" "$(field "$GOOD" metadata '{"k":"123.456.789-09"}')" 10 'dado-no-texto'
expect "node: teste em lib/tests/ conta como teste (o PS tem dois diretórios de teste)" "$(DESC 'lib/x.py e lib/tests/test_x.py')" 0 '"verdict": "node".*"tests": \["lib/tests/test_x.py"\]'
expect "node: o worktree de crew/worker (absoluto) é normalizado para o relativo" "$(DESC 'ver /Users/athos/gt/property_scrapers/crew/worker-ps-qrun/lib/foo.py e /Users/athos/gt/property_scrapers/tests/test_foo.py')" 0 '"paths": \["lib/foo.py", "tests/test_foo.py"\]'
expect "mini: crew/./ (segmento ponto) NÃO é prefixo de worktree: o caminho fica fora do formato" "$(DESC 'ver /Users/athos/gt/property_scrapers/crew/./lib/foo.py e tests/test_foo.py')" 10 'caminho-fora-do-formato'
expect "mini: rede viva (proxy) citada sem etiqueta (mole)" "$(DESC 'lib/x.py troca o proxy; tests/test_x.py')" 10 'moles:rede-viva'
expect "mini: rede viva ('na rodada real') citada sem etiqueta" "$(DESC 'lib/x.py; confirmar na rodada real; tests/test_x.py')" 10 'moles:rede-viva'
expect "mini: launchd/plist citado sem etiqueta (host Mac)" "$(DESC 'lib/x.py recarrega o launchd; tests/test_x.py')" 10 'moles:host-mac'
expect "mini: MotherDuck citado sem etiqueta (banco real)" "$(DESC 'lib/x.py grava no MotherDuck; tests/test_x.py')" 10 'moles:banco-de-dados'
expect "mini: ~/.property-scrapers (dado real do mini) sem etiqueta" "$(DESC 'lib/x.py le ~/.property-scrapers/shared; tests/test_x.py')" 10 'moles:banco-de-dados'
expect "node:ok ignora a rede viva e DIZ que ignorou" "$(labels "$(DESC 'lib/x.py troca o proxy; tests/test_x.py')" '["node:ok"]')" 0 'moles-ignoradas:rede-viva'
printf 'tests/test_scraper_auto_healer.py\n' > "$T/macs-ps-fixture.txt"; export PS_NODE_MAC_ONLY="$T/macs-ps-fixture.txt"
expect "mini: teste da lista mac-only do PS (fixture: a semente real pode encolher sem quebrar este caso)" "$(DESC 'lib/x.py e tests/test_scraper_auto_healer.py')" 10 'so-no-mac:tests/test_scraper_auto_healer\.py'
unset PS_NODE_MAC_ONLY
# a lista REAL do PS lê (tem globs) e não é a de outro rig: um teste do PS que SEMPRE esteve nela segue valendo, sem fixar qual
[ "$(grep -c '^[^#[:space:]]' "$HERE/hetzner-mac-only.ps.txt")" -ge 1 ] && ok "a semente mac-only real do PS tem ao menos um glob" || bad "a semente mac-only real do PS não tem nenhum glob"
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
expect "unknown: texto da bead acima do teto (truncar esconderia palavra)" "$(printf '{"id":"ps-b","title":"t","description":"lib/a.py tests/test_a.py %s"}' "$BIG")" 11 'texto-grande'
expect "unknown: entrada acima de 1 MB" "$(printf '{"id":"ps-b","title":"t","description":"%s"}' "$("$PY" -I -c 'print("x"*1100000)')")" 11 'entrada-grande'
expect "unknown: exceção que ninguém previu (JSON aninhado demais) também é inerte" "$("$PY" -I -c 'print("["*200000)')" 11 'erro-inesperado'

# ---- filtro, mac-only e rsync: falha de leitura = unknown, nunca node
export PS_NODE_FILTER="$T/nao-existe.txt"
expect "unknown: filtro ausente" "$GOOD" 11 'filtro-ilegivel'
unset PS_NODE_FILTER
echo '+ *.py' > "$T/filtro-incompleto.txt"; export PS_NODE_FILTER="$T/filtro-incompleto.txt"
expect "unknown: filtro sem a negação final" "$GOOD" 11 'filtro-sem-negacao-final'
unset PS_NODE_FILTER
export PS_NODE_MAC_ONLY="$T/nao-existe.txt"
expect "unknown: lista mac-only ausente (com caminhos citados)" "$GOOD" 11 'mac-only-ilegivel'
expect "mac-only ausente não pesa quando a bead não cita caminho (node:ok)" "$(labels "$NOPROOF" '["node:ok"]')" 0 '"verdict": "node"'
printf '# so comentario, nenhum glob\n' > "$T/macs-vazio.txt"; export PS_NODE_MAC_ONLY="$T/macs-vazio.txt"
expect "unknown: lista mac-only SEM nenhum glob (truncada?) não vira 'nada é só-Mac'" "$GOOD" 11 'mac-only-vazio'
unset PS_NODE_MAC_ONLY
printf '# só comentário\ntests/test_launchd_*.py\n' > "$T/macs.txt"; export PS_NODE_MAC_ONLY="$T/macs.txt"
expect "mini: teste que só roda no Mac" "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac:tests/test_launchd_plist\.py'
expect "node: lista mac-only que não casa não atrapalha" "$GOOD" 0 '"verdict": "node"'
unset PS_NODE_MAC_ONLY
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
printf '+ */\n+ *.py\n+ *\n- *\n' > "$T/filtro-furado.txt"   # termina em "- *" (passa a checagem da última regra) mas um `+ *` antes deixa tudo sair: só o canário pega
export PS_NODE_FILTER="$T/filtro-furado.txt"
expect "unknown: filtro furado ('+ *' antes do '- *' final) deixa sair canário de segredo" "$GOOD" 11 'canario-errado'
unset PS_NODE_FILTER
# o catch-all `- *` tem de ser a ÚLTIMA regra: "- *" como substring existe em `- *.pem` (Seção 1), então o filtro real SEM a última linha passava pela checagem de texto
sed '$d' "$REAL_FILTER" > "$T/filtro-sem-ultima.txt"; tail -n 1 "$T/filtro-sem-ultima.txt" | grep -qvx -- '- \*' && ok "(controle) a cópia do filtro real sem a última linha não termina em '- *'" || bad "controle: a cópia ainda termina em '- *'"
export PS_NODE_FILTER="$T/filtro-sem-ultima.txt"
expect "unknown: filtro real SEM a última linha ('- *') -> filtro-sem-negacao-final" "$GOOD" 11 'filtro-sem-negacao-final'
unset PS_NODE_FILTER
{ cat "$REAL_FILTER" | sed '$d'; printf '+ *\n- *\n'; } > "$T/filtro-mais-tudo.txt"   # termina em '- *' mas um `+ *` antes deixa TUDO sair: só o canário de nome não listado pega
export PS_NODE_FILTER="$T/filtro-mais-tudo.txt"
expect "unknown: filtro que termina em '- *' mas deixa sair o que ninguém lista (+ * antes) -> canario-errado" "$GOOD" 11 'canario-errado'
unset PS_NODE_FILTER
# argv do rsync no classificador: $1=-a $2=-n $3=--out-format $4=--filter $5=<origem>/ $6=<destino>/ (o destino é SEMPRE vazio: quem "lista tudo" lista a origem, $5)
stub rs-rc1 'exit 1'
stub rs-mudo 'exit 0'
stub rs-tudo 'cd "$5" && find . -type f | sed "s|^\./||"; exit 0'
stub rs-parcial 'printf "%s\n" lib/foo_parser.py tests/test_foo_parser.py tests/test_zz_ps_node_canary.py; exit 23'   # saída "boa" (canário de código + os arquivos do GOOD) com rc 23 (transferência parcial)
stub rs-pendura 'sleep 6; exit 0'
export PS_NODE_RSYNC="$T/rs-rc1";    expect "unknown: rsync sai com erro" "$GOOD" 11 'rsync-rc-1'
export PS_NODE_RSYNC="$T/rs-parcial"; expect "unknown: rsync que lista o esperado mas sai com rc 23 — saída boa não salva rc != 0" "$GOOD" 11 'rsync-rc-23'
export PS_NODE_RSYNC="$T/rs-mudo";   expect "unknown: rsync mudo (nenhum canário listado) — não vira 'nada sai'" "$GOOD" 11 'canario-errado'
export PS_NODE_RSYNC="$T/rs-tudo";   expect "unknown: rsync que lista TUDO (canário de segredo saiu)" "$GOOD" 11 'canario-errado'
export PS_NODE_RSYNC="$T/nao-existe-rsync"; expect "unknown: rsync inexistente" "$GOOD" 11 'rsync-sem-resposta'
export PS_NODE_RSYNC="$T/rs-pendura" PS_NODE_RSYNC_TIMEOUT=1; expect "unknown: rsync que não responde no prazo" "$GOOD" 11 'rsync-sem-resposta'
unset PS_NODE_RSYNC PS_NODE_RSYNC_TIMEOUT
export PS_NODE_RSYNC_TIMEOUT=abc; expect "prazo do rsync ilegível volta ao padrão (30) e não derruba" "$GOOD" 0 '"verdict": "node"'; unset PS_NODE_RSYNC_TIMEOUT

# ---- info: raspador citado que a lista de liberados do nó não libera (só informa; a decisão não muda)
printf '# lista de teste\nimoview\nvalore:tenant1\n!loft   # 503 trunca\n!quintoandar\n' > "$T/elig.txt"; export PS_NODE_ELIGIBLE="$T/elig.txt"
SC='scrapers/%s/scraper.py e tests/test_x.py'
expect "info: raspador bloqueado (!loft) vira raspador-fora-do-no, e a bead continua node" "$(DESC "$(printf "$SC" loft)")" 0 '"verdict": "node".*"info": \[.*"raspador-fora-do-no:loft"'
expect "info: raspador liberado (imoview) NÃO entra no info" "$(DESC "$(printf "$SC" imoview)")" 0 '"verdict": "node"' 
if ! printf '%s' "$OUT" | grep -q 'raspador-fora-do-no'; then ok "info: imoview liberado não gera raspador-fora-do-no"; else bad "info: imoview liberado gerou raspador-fora-do-no ($OUT)"; fi
expect "info: raspador que não aparece na lista NÃO roda no nó (nome desconhecido = fora)" "$(DESC "$(printf "$SC" zzdesconhecido)")" 0 '"info": \[.*"raspador-fora-do-no:zzdesconhecido"'
expect "info: raspador só liberado para um tenant (valore:tenant1) conta como liberado" "$(DESC "$(printf "$SC" valore)")" 0 '"verdict": "node"'
if ! printf '%s' "$OUT" | grep -q 'raspador-fora-do-no'; then ok "info: valore:tenant1 liberado não gera raspador-fora-do-no"; else bad "info: valore:tenant1 gerou raspador-fora-do-no ($OUT)"; fi
expect "info: nenhum raspador citado -> nenhum slug de raspador" "$GOOD" 0 '"info": \[\]'
export PS_NODE_ELIGIBLE="$T/nao-existe-elig.txt"
expect "info: lista de liberados ilegível -> lista-de-raspadores-ilegivel (não digo que está liberado), e a decisão não muda" "$(DESC "$(printf "$SC" imoview)")" 0 '"verdict": "node".*lista-de-raspadores-ilegivel'
printf '# so comentario\n' > "$T/elig-vazia.txt"; export PS_NODE_ELIGIBLE="$T/elig-vazia.txt"
expect "info: lista de liberados SEM nenhuma entrada (vazia/truncada) -> lista-de-raspadores-ilegivel, não 'nenhum liberado'" "$(DESC "$(printf "$SC" imoview)")" 0 'lista-de-raspadores-ilegivel'
printf 'imoview\n!alpha beta\n' > "$T/elig-ruim.txt"; export PS_NODE_ELIGIBLE="$T/elig-ruim.txt"
expect "info: linha que não é nome nem nome:tenant -> a lista INTEIRA é ilegível (um bloqueio que não casa liberaria em silêncio)" "$(DESC "$(printf "$SC" imoview)")" 0 'lista-de-raspadores-ilegivel'
unset PS_NODE_ELIGIBLE
# a Seção 1 do filtro do PS é a do WA (o espelho git lê a do WA: se divergirem, o classificador acha que sai o que o espelho nega, ou o contrário)
if diff <(sed -n '/^# SEÇÃO 1/,/^# SEÇÃO 2/p' "$HERE/hetzner-rsync-filter.wa.txt" | sed '$d') <(sed -n '/^# SEÇÃO 1/,/^# SEÇÃO 2/p' "$REAL_FILTER" | sed '$d') >/dev/null; then ok "Seção 1 do filtro do PS igual à do WA (byte a byte)"; else bad "Seção 1 do filtro do PS DIVERGE da do WA"; fi

# ---- o classificador não deixa resíduo e só aceita stdin
tmp_residue() { # tmp_residue <classificador> -> nº de itens que sobraram num TMPDIR só dele (a bead cita caminhos, então o classificador cria a árvore temporária)
  local d; d=$(mktemp -d "$T/tmpd.XXXXXX")
  printf '%s' "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" | PS_NODE_FILTER="$REAL_FILTER" PS_NODE_MAC_ONLY="$REAL_MAC" TMPDIR="$d" "$PY" -I "$1" >/dev/null 2>&1
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
  export PS_NODE_FILTER="$REAL_FILTER" PS_NODE_MAC_ONLY="$REAL_MAC"
  [ -n "$envspec" ] && export "$envspec"
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
  unset PS_NODE_FILTER PS_NODE_MAC_ONLY; [ -n "$envspec" ] && unset "${envspec%%=*}"
}
mutant sem-node-mini     '"node:mini" in labels'                       'False'                                  "$(labels "$GOOD" '["node:mini"]')" 10 'etiqueta-node:mini'
mutant sem-epic          'b.get("issue_type") == "epic"'               'False'                                  "$(field "$GOOD" issue_type '"epic"')" 10 '"epic"'
mutant sem-recusa        'if recusada_pelo_no(b):'                     'if False:'                              "$(labels "$(field "$GOOD" metadata '{"athos.node_recusa":"precisa do banco"}')" '["node:ok"]')" 10 'recusada-pelo-no'
mutant recusa-vazia-conta 'return v is not None and str(v).strip() != ""' 'return v is not None'                  "$(field "$GOOD" metadata '{"athos.node_recusa":"  "}')" 0 '"verdict": "node"'
mutant metadata-ilegivel-livre 'raise Unreadable("metadata-ilegivel")'   'return False'                            "$(field "$GOOD" metadata '"texto"')" 11 'metadata-ilegivel'
mutant sem-pii           'if has_pii(json.dumps'                       'if False and has_pii(json.dumps'        "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" 10 'dado-no-texto'
mutant pii-sem-cauda     'len(set(d[-8:])) > 3'                        'len(set(d[-8:])) >= 0'                  "$(DESC 'lib/x.py tests/test_x.py +55 31 99999-9999')" 0 '"verdict": "node"'
mutant filtro-ignorado   'if p not in sent:'                           'if False:'                              "$WITHDB" 10 'caminho-fora-do-filtro'
mutant mac-ignorado      'elif any(fnmatch.fnmatchcase(p, g) for g in globs):' 'elif False:'                    "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac' "PS_NODE_MAC_ONLY=$T/macs.txt"
# o canário tem DUAS metades (o de código TEM de sair, os de segredo NÃO): um mutante por metade e um para as duas; cada um com o rsync que só ELE separa do original
mutant sem-canario       'if CANARY_OK not in sent or any(c in sent for c in CANARY_NO):' 'if False:'          "$GOOD" 11 'canario-errado' "PS_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-codigo 'CANARY_OK not in sent or any('              'False or any('                          "$GOOD" 11 'canario-errado' "PS_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-segredo 'or any(c in sent for c in CANARY_NO):'    'or False:'                              "$GOOD" 11 'canario-errado' "PS_NODE_RSYNC=$T/rs-tudo"
mutant rc-ignorado       'if r.returncode != 0:'                       'if False:'                              "$GOOD" 11 'rsync-rc-23' "PS_NODE_RSYNC=$T/rs-parcial"
mutant sem-moles         'if soft and not override:'                   'if False:'                              "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
mutant label-ignorada    'override = "node:ok" in labels'              'override = False'                       "$(labels "$NOPROOF" '["node:ok"]')" 0 'label'
mutant prova-frouxa      'if tests and code:'                          'if tests or True:'                      "$NOPROOF" 11 'sem-prova'
mutant unreadable-node   'v, why, paths, tests, info = "unknown", ["nao-consegui:"' 'v, why, paths, tests, info = "node", ["nao-consegui:"' 'isto nao e json' 11 'json-ilegivel'
# caminho fora do formato: as checagens explícitas ('/' inicial, '', '.', '..') são SUBSUMIDAS por SAFE_SEG (que recusa segmento vazio ou começado em ponto) — tirar só elas é mutante equivalente e não se lista.
# Mata-se a condição inteira e, separado, só o SAFE_SEG (o caso de letra não-ASCII é o que só ele segura).
mutant caminho-solto     'if p.startswith("/") or any(s in ("", ".", "..") for s in segs) or not all(SAFE_SEG.match(s) for s in segs):' 'if False:' "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
mutant sem-safe-seg      ' or not all(SAFE_SEG.match(s) for s in segs):' ':'                                  "$(DESC 'lib/x.py tests/test_x.py e lib/ação.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
mutant sem-teto-texto    'if len(text) > MAX_TEXT:'                    'if False:'                              "$(printf '{"id":"ps-b","title":"t","description":"lib/a.py tests/test_a.py %s"}' "$BIG")" 11 'texto-grande'
mutant labels-frouxas    'if not isinstance(lab, list) or not all(isinstance(x, str) for x in lab):' 'if False:' "$(labels "$GOOD" '"node:ok"')" 11 'labels-ilegiveis'
mutant abs-vira-mole     'norm(REPO_ABS_RE.sub("", text))'             'norm(text)'                             "$(DESC 'ver /Users/athos/gt/property_scrapers/lib/foo.py e tests/test_foo.py')" 0 '"verdict": "node"'
mutant sem-catch-all    'except Exception as e:'                      'except ZeroDivisionError as e:'         "$("$PY" -I -c 'print("["*200000)')" 11 'erro-inesperado'
mutant teto-frouxo       'if len(out) >= MAX_PATHS:'                   'if len(out) > MAX_PATHS:'               "$(DESC "${P39}lib/m40.py tests/test_x.py")" 10 'caminhos-demais'
mutant sufixo-vira-arquivo '(?![\w\-]|\.\w)'                           '(?![\w])'                               "$(DESC 'lib/x.py.bak e tests/test_x.py')" 11 '"paths": \["tests/test_x\.py"\]'
mutant sem-maiuscula     ', re.IGNORECASE)'                            ')'                                      "$(DESC 'lib/x.py tests/test_x.py e DATA/Leads.CSV')" 10 'caminho-fora-do-filtro:DATA/Leads\.CSV'   # 1ª ocorrência = PATH_RE (HOME_RE vem depois)
mutant sem-sqlite3       '|db|sqlite3?|xlsx|'                          '|db|sqlite|xlsx|'                       "$(DESC 'lib/x.py tests/test_x.py e data/x.sqlite3')" 10 'caminho-fora-do-filtro:data/x\.sqlite3'
mutant sem-rede-viva     'proxy|proxies|'                              ''                                       "$(DESC 'lib/x.py troca o proxy; tests/test_x.py')" 10 'moles:rede-viva'
mutant sem-launchd       '\blaunchd\b|'                           ''                                       "$(DESC 'lib/x.py recarrega o launchd; tests/test_x.py')" 10 'moles:host-mac'
mutant sem-motherduck    '|motherduck'                                 ''                                       "$(DESC 'lib/x.py grava no MotherDuck; tests/test_x.py')" 10 'moles:banco-de-dados'
mutant worktree-nao-normaliza '(?:crew/[\w\-][\w.\-]*/)?'                    ''                                       "$(DESC 'ver /Users/athos/gt/property_scrapers/crew/worker-ps-qrun/lib/foo.py e /Users/athos/gt/property_scrapers/tests/test_foo.py')" 0 '"paths": \["lib/foo.py", "tests/test_foo.py"\]'
mutant info-raspador-mudo 'return ["raspador-fora-do-no:" + n for n in names if n.lower() in blocked or n.lower() not in allowed]' 'return []' "$(DESC "$(printf "$SC" loft)")" 0 'raspador-fora-do-no:loft' "PS_NODE_ELIGIBLE=$T/elig.txt"
mutant info-lista-ilegivel-vira-liberado $'    except (OSError, UnicodeError):\n        return ["lista-de-raspadores-ilegivel"]' $'    except (OSError, UnicodeError):\n        return []' "$(DESC "$(printf "$SC" imoview)")" 0 'lista-de-raspadores-ilegivel' "PS_NODE_ELIGIBLE=$T/nao-existe-elig.txt"
mutant filtro-so-substring 'if not rules or rules[-1] != "- *":' 'if "- *" not in "\n".join(rules):' "$GOOD" 11 'filtro-sem-negacao-final' "PS_NODE_FILTER=$T/filtro-sem-ultima.txt"
mutant sem-canario-nao-listado ', "zz_ps_node_canary.unlisted")' ')' "$GOOD" 11 'canario-errado' "PS_NODE_FILTER=$T/filtro-mais-tudo.txt"
mutant crew-aceita-ponto  '(?:crew/[\w\-][\w.\-]*/)?' '(?:crew/[\w.\-]+/)?' "$(DESC 'ver /Users/athos/gt/property_scrapers/crew/./lib/foo.py e tests/test_foo.py')" 10 'caminho-fora-do-formato'
mutant lista-vazia-vale-nenhum 'if not allowed and not blocked:' 'if False:' "$(DESC "$(printf "$SC" imoview)")" 0 'lista-de-raspadores-ilegivel' "PS_NODE_ELIGIBLE=$T/elig-vazia.txt"
mutant linha-ruim-e-pulada 'return ["lista-de-raspadores-ilegivel"]   # linha que não é' 'continue   # linha que não é' "$(DESC "$(printf "$SC" imoview)")" 0 'lista-de-raspadores-ilegivel' "PS_NODE_ELIGIBLE=$T/elig-ruim.txt"
mutant sem-home          'if HOME_RE.search(text):'                    'if False:'                              "$(DESC 'lib/x.py tests/test_x.py e ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
mutant mac-vazio-vale    'if not globs:'                               'if False:'                              "$GOOD" 11 'mac-only-vazio' "PS_NODE_MAC_ONLY=$T/macs-vazio.txt"
# o resíduo no TMPDIR: o mutante que não apaga a árvore tem de deixar item para trás (senão o teste de "sem resíduo" passaria mesmo sem a limpeza)
if mk_mutant sem-limpeza 'shutil.rmtree(root, ignore_errors=True)' 'pass'; then
  left=$(tmp_residue "$T/mut-sem-limpeza.py")
  [ "${left:-0}" -ge 1 ] && ok "mutante sem-limpeza morreu" || bad "mutante sem-limpeza SOBREVIVEU (sem apagar a árvore o TMPDIR ficou com $left item(ns))"
else bad "mutante sem-limpeza: o trecho original não existe (o classificador mudou? atualize o mutante)"; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
