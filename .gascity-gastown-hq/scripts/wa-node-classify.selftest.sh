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
#   envio no texto manda ao mini (freio-derivado; lead/terreno/lote/construtora NÃO freiam mais, ga-2hd02v.3.21; bug/feature também não, ga-v8p1tx.1.3: só task/chore/sem tipo, e a regra 9 não muda); repo/ref/git/grep/espelho que falham dão unknown COM a nota e vazio dá unknown SEM nota (três estados).
#   · CÓDIGO DERIVADO DO TESTE (ga-2hd02v.3.21, regra 8): teste citado e NENHUM código -> o código que o teste IMPORTA (import/from em Python por ast, require/import em JS, lidos em origin/main); só existente e de código (não tests/),
#   pelos MESMOS filtros do citado (fora do filtro / só no Mac = mini; mais de 10 = nenhum); a regra 7 e a 5 vencem a 8; teste novo, sem import do repo, import dinâmico ou apoio de teste = unknown SEM nota; git show/parse/repo que falham = unknown COM a nota.
#   · EVIDÊNCIA ≠ DEPENDÊNCIA (ga-t05a1z9): banco/log/json citado como PROVA vira `info` (evidencia-de-dado:/evidencia-de-doc:) e não barra, mas só com >=1 código citado que o filtro deixa passar; segue duro dado sem
#   código, código fora do filtro, .plist/.sql/.env, nome com cara de segredo (português também) e telefone/CPF; absoluto/~/$HOME de dado também é evidência; o token sai do texto das moles (do mais longo ao mais curto).
#   · MOLES POR EVIDÊNCIA (ga-qkc02kk, regra 4): a palavra mole na bead é prosa e só informa; o código dos arquivos de prova (lido em origin/main) é que barra. Três estados: leu e achou (nome de banco solto, caminho fixado, argv/chamada do cofre,
#   osascript/launchctl/security, perfil do Chrome) -> mini mesmo SEM palavra; leu e não achou (docstring/comentário, connect(variável), env de token, `import secrets`, /Users/… sozinho, banco solto em TESTE) -> a palavra vai em info;
#   o Python que parseia acha o MESMO idioma que o texto de .sh/.js (gate-fix 1): binário do cofre com caminho, linha de shell/f-string ("secret x"), wrapper do repo (secret_bin/lib.secret_cli), connect_over_cdp/run_osascript como chamada,
#   `security` com caminho/em linha de shell, banco em f-string, DDL `CREATE SECRET` do DuckDB; prosa em string ("the secret key…", "httpfs/secret S3", "lib/security") não conta;
#   não consegui ler (repo, arquivo > 1 MB) ou tudo é novo -> a palavra volta a barrar, com a nota. Código só das irmãs é palpite (informa); o que a bead NOMEIA barra; node:ok, exec:manual, PII e freio de envio não mudam.
#   · TESTE IMPORTADOR (regra 6b): código sem teste de nome ganha os testes que o IMPORTAM (import estático que resolve para o mesmo arquivo; string/comentário não conta — em JS, require em comentário não conta e require em string conta; não parseia
#   é pulado e contado; mais de 60 candidatos: o excesso não é lido e a nota avisa; git que falha = unknown com a nota).
#   · ORÁCULO = TESTE VERMELHO EM MAIN (ga-2hd02v.5.13, regra 9): BUG que cita >=1 teste (que existe em origin/main) e nenhum código, com a palavra de vermelho (reprova/falha/vermelho/quebrado/fail) na MESMA frase de um `main` (origin/main, «em main») -> node derivado
#   (6 casos com o texto de beads WA reais); tarefa, sem a palavra, frase cortada, negação colada («não reprova»), «passa em main», «main thread», sem teste citado e teste ausente de main (com a nota) = unknown; envio = mini; banco fixado no teste = mini (moles);
#   as regras 5, 7 e 8 vencem a 9 e a leitura que falhou (regra 7 ou 8) a impede de rodar (nunca node).
#   · ÂNCORA DO DADO (regra 3): a bead que cita só dado e NOMEIA o módulo é ancorada pelo código derivado (mesmos filtros); sem âncora/fora do nó/leitura que falha o dado segue duro; PII e item que não é evidência impedem a tentativa.
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
export WA_NODE_SCHEMA_RECEIPT="$T/receipt-ausente.json"   # banco com schema no nó (ga-kzwlkhh): os casos antigos valem SEM recibo (nunca o do .gc/ de verdade); a seção "banco com schema" liga recibos de mentira

CLS="$CLS_REAL"; OUT=""; RC=0
run() { OUT=$(printf '%s' "$1" | "$PY" -I "$CLS" 2>/dev/null); RC=$?; }
# check <json> <rc> <regex da saída> -> 0 se o rc é o esperado e a saída casa; sem imprimir (os mutantes usam o mesmo)
check() { run "$1"; [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -q -E -e "$3"; }
expect() { # expect <rótulo> <json> <rc> <regex>
  if check "$2" "$3" "$4"; then ok "$1"; else bad "$1 (rc=$RC, esperado $3; saída: $(printf '%s' "$OUT" | cut -c1-230))"; fi
}
expect_not() { # expect_not <rótulo> <json> <rc> <regex que NÃO pode aparecer na saída> — o rc tem de bater E a saída não pode casar (ex.: o doc retido NÃO chegou pelo espelho)
  run "$2"
  if [ "$RC" = "$3" ] && ! printf '%s' "$OUT" | grep -q -E -e "$4"; then ok "$1"; else bad "$1 (rc=$RC, esperado $3 sem /$4/; saída: $(printf '%s' "$OUT" | cut -c1-230))"; fi
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
expect "mini: etiqueta exec:manual (um humano executa à mão) - nem a prova de código+teste a leva ao nó (ga-qkc02kk)" "$(labels "$GOOD" '["exec:manual"]')" 10 '"reasons": \["etiqueta-exec:manual"\]'
expect "mini: exec:manual também vence node:ok (decisão de executar à mão não é palavra mole)" "$(labels "$GOOD" '["node:ok","exec:manual"]')" 10 'etiqueta-exec:manual'
expect "mini: epic" "$(field "$GOOD" issue_type '"epic"')" 10 '"reasons": \["epic"\]'
expect "mini: banco .db citado SEM código (o filtro segura; evidência exige código citado, ga-t05a1z9)" "$(DESC 'o teste tests/test_x.py mede queue.db')" 10 'caminho-fora-do-filtro:queue\.db'
expect "mini: banco citado em PROSA ainda é mole, mesmo com o .db virando evidência (ga-t05a1z9)" "$WITHDB" 10 'moles:banco-de-dados'
expect "mini: pasta data/ citada (o filtro segura mesmo sendo .py)" "$(DESC 'lib/x.py usa data/helper.py; tests/test_x.py')" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "mini: credentials*.json citado" "$(DESC 'lib/x.py lê config/credentials_prod.json; tests/test_x.py')" 10 'caminho-fora-do-filtro:config/credentials_prod\.json'
expect "mini: doc .md fora do filtro, SEM espelho legível (cai no filtro do rsync e diz por quê)" "$(DESC 'lib/x.py conforme docs/guia.md; tests/test_x.py')" 10 'caminho-fora-do-filtro:docs/guia\.md.*espelho-ilegivel:espelho-sem-resposta'
expect "mini: telefone real no texto (duro)" "$(DESC 'lib/x.py tests/test_x.py cliente (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "mini: CPF dentro da metadata (duro)" "$(field "$GOOD" metadata '{"k":"123.456.789-09"}')" 10 'dado-no-texto'
expect "mini: banco citado sem etiqueta (mole)" "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" 10 'moles:banco-de-dados'
expect "mini: credencial citada sem etiqueta" "$(DESC 'lib/x.py usa o token do pdpj; tests/test_x.py')" 10 'moles:credencial'
expect "mini: host Mac citado sem etiqueta" "$(DESC 'lib/x.py roda osascript; tests/test_x.py')" 10 'moles:host-mac'
expect "node:ok ignora a mole e DIZ que ignorou" "$(labels "$(DESC 'lib/x.py abre um sqlite; tests/test_x.py')" '["node:ok"]')" 0 'moles-ignoradas:banco-de-dados'
expect "duro vence node:ok: caminho que o filtro segura" "$(labels "$(DESC 'lib/x.py usa data/helper.py; tests/test_x.py')" '["node:ok"]')" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "duro vence node:ok: dado SEM código citado (evidência exige código, ga-t05a1z9)" "$(labels "$(DESC 'o teste tests/test_x.py mede queue.db')" '["node:ok"]')" 10 'caminho-fora-do-filtro:queue\.db'
expect "duro vence node:ok: telefone no texto" "$(labels "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" '["node:ok"]')" 10 'dado-no-texto'
expect "caminho com .. : fora do formato, não entra na lista que vai ao disco" "$(DESC 'lib/x.py e ../escape.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "caminho absoluto: fora do formato" "$(DESC 'lib/x.py e /etc/zz_evil.py com tests/test_x.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "caminho com letra não-ASCII: fora do formato (SAFE_SEG)" "$(DESC 'lib/x.py tests/test_x.py e lib/ação.py')" 10 'caminho-fora-do-formato.*"paths": \["lib/x\.py", "tests/test_x\.py"\]'
expect "~/caminho: host Mac, fora do formato" "$(DESC 'lib/x.py tests/test_x.py e ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
expect '$HOME/caminho: host Mac, fora do formato' "$(DESC 'lib/x.py tests/test_x.py e $HOME/bin/y.sh')" 10 'caminho-fora-do-formato'
expect "extensão em MAIÚSCULA também passa pelo filtro (sem código citado: o dado segue duro)" "$(DESC 'tests/test_x.py e DATA/Leads.CSV')" 10 'caminho-fora-do-filtro:DATA/Leads\.CSV'
expect ".sqlite3 citado (o filtro segura; sem código citado segue duro)" "$(DESC 'tests/test_x.py e data/x.sqlite3')" 10 'caminho-fora-do-filtro:data/x\.sqlite3'
P39=$(for i in $(seq 1 39); do printf 'lib/m%d.py ' "$i"; done)
expect "node: exatamente 40 caminhos (39 de código + 1 teste) ainda valem" "$(DESC "${P39}tests/test_x.py")" 0 '"verdict": "node"'
expect "mini: o 41º caminho estoura o teto" "$(DESC "${P39}lib/m40.py tests/test_x.py")" 10 'caminhos-demais'
# ---- evidência ≠ dependência (ga-t05a1z9): a bead cita banco/log/json como PROVA ("medido em queue.db"). O caminho de DADO que o nó NÃO recebe vira `info` (evidencia-de-dado:) e nunca vai ao nó, mas só se a bead cita
#      >=1 arquivo de CÓDIGO que o filtro deixa passar. Segue duro: dado sem código citado, código fora do filtro, .plist/.sql/.env, nome com cara de segredo (em português também) e telefone/CPF no texto.
EVID='{"id":"wa-e1","title":"scripts/foo.py devolve lista vazia","description":"Medido em queue.db: 3 linhas sem dono. Corrigir scripts/foo.py; teste em tests/test_foo.py"}'
expect "evidência: .db citado como prova + código + teste = node, e a bead DIZ que o .db foi evidência" "$EVID" 0 '"verdict": "node".*"info": \[.*"evidencia-de-dado:queue\.db"'
expect "evidência: o caminho continua em paths (nada some em silêncio)" "$EVID" 0 '"paths": \["scripts/foo\.py", "queue\.db", "tests/test_foo\.py"\]'
expect "evidência: o .db citado sozinho NÃO dispara a mole de banco (a palavra .db veio do próprio caminho)" "$EVID" 0 '"reasons": \["prova-no-texto:1-teste\(s\)\+1-codigo"\]'
expect "evidência: .log .json .sqlite .csv .jsonl .parquet também" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em a.log b/c.json d.sqlite e.csv f.jsonl g.parquet')" 0 '"verdict": "node".*evidencia-de-dado:a\.log.*evidencia-de-dado:b/c\.json.*evidencia-de-dado:d\.sqlite.*evidencia-de-dado:e\.csv.*evidencia-de-dado:f\.jsonl.*evidencia-de-dado:g\.parquet'
expect "evidência: etiqueta node:ok não muda o que é evidência" "$(labels "$EVID" '["node:ok"]')" 0 '"basis": "label".*evidencia-de-dado:queue\.db'
expect "evidência: SEM código citado o dado segue duro" "$(DESC 'o teste tests/test_foo.py mede queue.db')" 10 'caminho-fora-do-filtro:queue\.db'
expect "evidência: código que o filtro NÃO deixa passar não conta como código citado (dado e código seguem duros)" "$(DESC 'data/helper.py mede queue.db; tests/test_foo.py')" 10 'caminho-fora-do-filtro:data/helper\.py", "caminho-fora-do-filtro:queue\.db'
expect "evidência: com código bom citado, só o código fora do filtro vira motivo (o .db não)" "$(DESC 'scripts/foo.py usa data/helper.py e mede queue.db; tests/test_foo.py')" 10 '"reasons": \["caminho-fora-do-filtro:data/helper\.py"\]'
expect "evidência: nome com cara de segredo segue duro (senha)" "$(DESC 'scripts/foo.py lê config/senha_prod.json; tests/test_foo.py')" 10 'caminho-fora-do-filtro:config/senha_prod\.json'
expect "evidência: pasta com cara de segredo segue dura (segredos, em português)" "$(DESC 'scripts/foo.py lê dados/segredos/x.csv; tests/test_foo.py')" 10 'caminho-fora-do-filtro:dados/segredos/x\.csv'
expect "evidência: palavra INTEIRA key segue dura (map_key.json)" "$(DESC 'scripts/foo.py lê config/map_key.json; tests/test_foo.py')" 10 'caminho-fora-do-filtro:config/map_key\.json'
expect "evidência: key dentro de outra palavra NÃO é segredo (monkey_patch.json)" "$(DESC 'scripts/foo.py lê config/monkey_patch.json; tests/test_foo.py')" 0 'evidencia-de-dado:config/monkey_patch\.json'
expect "evidência: caminho ABSOLUTO de dado (fora do formato) também, sem disparar host-mac" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em /Users/athos/shared/data/v.db')" 0 '"verdict": "node".*evidencia-de-dado:/Users/athos/shared/data/v\.db'
expect "evidência: ~/ de dado também" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em ~/shared/data/v.db')" 0 'evidencia-de-dado:~/shared/data/v\.db'
expect 'evidência: $HOME/ de dado também' "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em $HOME/dados/y.csv')" 0 'evidencia-de-dado:\$HOME/dados/y\.csv'
expect "evidência: molde de nome (<data>-x.json) também" "$(DESC 'scripts/foo.py e tests/test_foo.py; fragmento lib/changelog.d/<data>-wa-x.json')" 0 'evidencia-de-dado:-wa-x\.json'
expect "evidência: .plist do home segue duro (artefato de host, não dado)" "$(DESC 'scripts/foo.py e tests/test_foo.py; plist em ~/Library/LaunchAgents/com.x.plist')" 10 'caminho-fora-do-formato'
expect "evidência: ~/segredos/chave.json segue duro mesmo com código citado" "$(DESC 'scripts/foo.py e tests/test_foo.py; ver ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
expect "evidência: nome solto + o absoluto que o contém não deixam sobrar host-mac (tira o mais longo primeiro)" "$(DESC 'scripts/foo.py e tests/test_foo.py; lot.db medido em /Users/athos/shared/data/m/lot.db')" 0 '"verdict": "node"'
expect "evidência não vence telefone/CPF no texto" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em queue.db, cliente (31) 98876-5432')" 10 '"reasons": \["dado-no-texto"\]'
expect "evidência: credencial escrita em PROSA segue mole (e é a única razão: o .db não soma banco)" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em queue.db; o token expira')" 10 '"reasons": \["moles:credencial"\]'
expect "evidência: banco escrito em PROSA segue mole" "$(DESC 'scripts/foo.py e tests/test_foo.py; medido em queue.db; abre o banco')" 10 '"reasons": \["moles:banco-de-dados"\]'
EV10=$(for i in 1 2 3 4 5 6 7 8 9 10; do printf 'x%d.log ' "$i"; done)
expect "evidência: o info nomeia até 8 e conta o resto" "$(DESC "scripts/foo.py tests/test_foo.py medido em ${EV10}")" 0 'evidencia-de-dado:x8\.log", "evidencia-de-dado-mais:2"'
expect_not "evidência: a 9ª não é nomeada" "$(DESC "scripts/foo.py tests/test_foo.py medido em ${EV10}")" 0 'evidencia-de-dado:x9\.log'

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
expect "mini: .md que a varredura de CONTEÚDO sinalizou (espelho nega), SEM código citado, segue fora" "$(DESC "tests/test_x.py conforme docs/sinalizado.md")" 10 'caminho-fora-do-filtro:docs/sinalizado\.md'
# ga-t05a1z9: o retido pela varredura (docs/data_dictionary.md: 38 telefones e 4 CPFs) NUNCA vai ao nó; com código citado a bead deixa de ser barrada por ele e o doc vira evidência (não "via-espelho")
expect "evidência de DOC: .md que a varredura reteve + código citado = node, como evidencia-de-doc" "$(DESC "${DOCS}docs/sinalizado.md")" 0 '"verdict": "node".*"info": \[.*"evidencia-de-doc:docs/sinalizado\.md"'
expect_not "evidência de DOC: o retido NÃO aparece como entregue pelo espelho" "$(DESC "${DOCS}docs/sinalizado.md")" 0 'via-espelho:docs/sinalizado'
expect "mini: .md em pasta que o rsync NUNCA deixa sair (shared/), mesmo o espelho não negando" "$(DESC "${DOCS}shared/notas.md")" 10 'caminho-fora-do-filtro:shared/notas\.md'
expect "mini: .md dentro de logs/ (pasta de dado), SEM código citado, segue fora" "$(DESC "tests/test_x.py conforme logs/relatorio.md")" 10 'caminho-fora-do-filtro:logs/relatorio\.md'
expect "evidência: .md dentro de logs/ + código citado = evidencia-de-dado (o espelho NÃO o entrega)" "$(DESC "${DOCS}logs/relatorio.md")" 0 'evidencia-de-dado:logs/relatorio\.md'
expect "mini: .json neutro em docs/ NÃO ganha o espelho (só texto .md), SEM código citado" "$(DESC "tests/test_x.py conforme docs/auto_response/ab_results/x.json")" 10 'caminho-fora-do-filtro:docs/auto_response/ab_results/x\.json'
expect_not "evidência: .json neutro em docs/ + código vira evidencia-de-dado, NUNCA via-espelho" "$(DESC "${DOCS}docs/auto_response/ab_results/x.json")" 0 'via-espelho'
expect "mini: .txt neutro em docs/ também não" "$(DESC "${DOCS}docs/notas.txt")" 10 'caminho-fora-do-filtro:docs/notas\.txt'
expect "mini: um .md entregue e um código fora do filtro na mesma bead — o código segura" "$(DESC "${DOCS}docs/guia.md e data/helper.py")" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "node: um .md entregue e um .db citado como prova — o .db é evidência, o .md vem pelo espelho" "$(DESC "${DOCS}docs/guia.md e queue.db")" 0 'evidencia-de-dado:queue\.db.*via-espelho:docs/guia\.md|via-espelho:docs/guia\.md.*evidencia-de-dado:queue\.db'
expect "mini: .md entregue + .md sinalizado, SEM código — só o sinalizado vira motivo" "$(DESC "tests/test_x.py conforme docs/guia.md e docs/sinalizado.md")" 10 '"reasons": \["caminho-fora-do-filtro:docs/sinalizado\.md"\]'
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
# cópia de backup versionada (ga-2hd02v.3.22; o repo do WA tem lib.bak-*, daemons.bak-*, scripts.bak-*, archive/): bak_viva_mod mora em lib/ E em lib.bak-*/ (o NOME do arquivo tem `bak` de propósito: só a PASTA marca cópia);
# so_copia_mod só existe na cópia; amb_copia_mod mora em 2 pastas vivas + 2 cópias (são 4 > 3 só se a cópia contar); arq_viva_mod tem a cópia em archive/; o commit da irmã wa-par6.1 toca irma_copia_mod vivo E a cópia
wf lib/bak_viva_mod.py "# bak_viva_mod"; wf lib.bak-20260313-200326/bak_viva_mod.py "# bak_viva_mod velho"; wf tests/test_bak_viva_mod.py "bak_viva_mod"
wf daemons.bak-20260313-200324/so_copia_mod.py "# so_copia_mod velho"; wf tests/test_so_copia_mod.py "so_copia_mod"
for d in lib daemons lib.bak-20260313-200326 scripts.bak-20260313-200328; do wf "$d/amb_copia_mod.py" "# amb_copia_mod"; done; wf tests/test_amb_copia_mod.py "amb_copia_mod"
wf lib/arq_viva_mod.py "# arq_viva_mod"; wf archive/arq_viva_mod.py "# arq_viva_mod velho"; wf tests/test_arq_viva_mod.py "arq_viva_mod"
wf lib/irma_copia_mod.py "# irma_copia_mod"; wf lib.bak-20260313-200326/irma_copia_mod.py "# irma_copia_mod velho"; wf tests/test_irma_copia_mod.py "irma_copia_mod"
gw add lib/irma_copia_mod.py lib.bak-20260313-200326/irma_copia_mod.py && gw commit -q -m "feat(wa-par6.1): irma_copia_mod" || bad "commit da irma com copia nao montado"
gw add daemons.bak-20260313-200324/so_copia_mod.py && gw commit -q -m "feat(wa-par7.1): so_copia_mod" || bad "commit da irma so com copia nao montado"   # wa-par7.1 tocou só a cópia (nenhum homônimo vivo)
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
# regra 8 (ga-2hd02v.3.21): código que o TESTE citado importa. imp_alpha/imp_beta/imp_js_* são código; cada tests/test_imp_* importa de um jeito (e tests/imp_support.py é apoio de teste, não código)
wf lib/imp_alpha.py "# imp_alpha"; wf lib/imp_beta.py "# imp_beta"; wf lib/imp_js_mod.js "// imp_js_mod"; wf lib/imp_js_dir/index.js "// imp_js_dir"; wf lib/imp_js_esm.mjs "// imp_js_esm"; wf tests/imp_support.py "# apoio de teste"
wf tests/test_imp_a.py "from lib.imp_alpha import x"; wf tests/test_imp_bare.py $'import sys\nimport imp_alpha'
wf tests/test_imp_from.py $'from lib import imp_alpha, imp_beta\nfrom lib.imp_alpha import *'; wf tests/test_imp_fn.py $'def test_x():\n    from lib.imp_beta import y\n    assert y'
wf tests/test_imp_rel.py "from ..lib.imp_alpha import x"
wf tests/test_imp_stdlib.py $'import os, json\nimport pytest\nfrom pathlib import Path'; wf tests/test_imp_dyn.py $'import importlib\nmod = importlib.import_module("lib.imp_alpha")'
wf tests/test_imp_quebrado.py "def (:"; wf tests/test_imp_vazio.py ""; wf tests/test_imp_apoio.py "from tests.imp_support import algo"
wf tests/test_imp_fora.py "from shared.fora_mod import x"; wf tests/test_imp_mac.py "from lib.mac_code_mod import x"
wf tests/test_imp_sete.py "$(for i in 01 02 03 04 05 06 07; do printf 'from lib.limcap_%s import x\n' "$i"; done)"; wf tests/test_imp_onze.py "$(for i in 01 02 03 04 05 06 07 08 09 10 11; do printf 'from lib.limcap_%s import x\n' "$i"; done)"
wf tests/test_imp_head.py "import os"   # em origin/main não importa nada; no HEAD (2º commit) importa imp_alpha: o nó recebe origin/main
wf tests/test_imp_js.cjs $'const a = require(\'../lib/imp_js_mod.js\');\nconst d = require("../lib/imp_js_dir");\nconst fs = require(\'fs\');\nconst npm = require(\'imp_pacote_npm\');'; wf tests/test_imp_esm.mjs "import y from '../lib/imp_js_esm.mjs';"
{ printf '# '; head -c 1100000 /dev/zero | tr '\0' x; printf '\n'; } > "$RP/tests/test_imp_grande.py"   # acima do teto de 1 MB de leitura
# moles por EVIDÊNCIA (ga-qkc02kk, regra 4), teste IMPORTADOR (regra 6b) e âncora do dado (regra 3): um arquivo de mentira para cada estado. mole_clean só tem as palavras em docstring/comentário e conecta a uma VARIÁVEL (nada disso é
# evidência); mole_db/mole_pin/mole_cred/mole_credfn/mole_host/mole_secarg/mole_shhost/mole_jshost/mole_broken mostram o que CONTA (nome de banco solto, caminho fixado, argv do cofre, chamada _secret, osascript, security, launchctl) e
# mole_stdsec/mole_envtok/mole_users/mole_shclean/mole_brokencm o que NÃO conta (`import secrets` da stdlib, env de token, /Users/… sozinho, comentário). O teste de mole_tbare tem "queue.db" solto (teste cria banco em tmp: não conta); o de mole_tpin fixa o caminho de produção.
wf lib/mole_clean.py $'"""Abre queue.db com o secret do Bitwarden (so aqui, na docstring)."""\nimport sqlite3\n# secret("x") e osascript so em comentario\ndef abre(db):\n    return sqlite3.connect(db)'
wf tests/test_mole_clean.py $'import sqlite3\nfrom lib.mole_clean import abre\nDB = "queue.db"\ndef test_x(tmp_path):\n    abre(str(tmp_path / DB))'
wf lib/mole_db.py $'import os\nDB = os.path.join("shared", "data", "queue.db")'; wf tests/test_mole_db.py $'from lib.mole_db import DB'
wf lib/mole_pin.py $'P = "shared/data/x.db"'; wf tests/test_mole_pin.py $'from lib.mole_pin import P'
wf lib/mole_cred.py $'import subprocess\ndef tok():\n    return subprocess.run(["secret", "motherduck-token"])'; wf tests/test_mole_cred.py $'from lib.mole_cred import tok'
wf lib/mole_credfn.py $'def _secret(n):\n    return n\nTOK = _secret("x")'; wf tests/test_mole_credfn.py $'from lib.mole_credfn import TOK'
wf lib/mole_stdsec.py $'import secrets\nX = secrets.token_hex(8)'; wf tests/test_mole_stdsec.py $'from lib.mole_stdsec import X'
wf lib/mole_envtok.py $'import os\nT = os.environ.get("WHAPI_TOKEN")'; wf tests/test_mole_envtok.py $'from lib.mole_envtok import T'
wf lib/mole_host.py $'import subprocess\nsubprocess.run(["osascript", "-e", "x"])'; wf tests/test_mole_host.py $'from lib.mole_host import subprocess'
wf lib/mole_secarg.py $'import subprocess\nsubprocess.run(["security", "find-generic-password"])'; wf tests/test_mole_secarg.py $'from lib.mole_secarg import subprocess'
wf lib/mole_users.py $'HOME = "/Users/athos/x"'; wf tests/test_mole_users.py $'from lib.mole_users import HOME'
wf lib/mole_shclean.sh $'#!/bin/sh\n# launchctl so no comentario\necho oi'; wf tests/test_mole_shclean.py $'mole_shclean'
wf lib/mole_shhost.sh $'#!/bin/sh\nlaunchctl list'; wf tests/test_mole_shhost.py $'mole_shhost'
wf lib/mole_jshost.js $'const cp = require(\'child_process\');\ncp.execSync(\'osascript -e x\');'; wf tests/test_mole_jshost.cjs $'mole_jshost'
wf lib/mole_broken.py $'def (:\nDB = "queue.db"'; wf tests/test_mole_broken.py $'mole_broken'                    # Python que não parseia: lê o texto (mais largo) e acha queue.db
wf lib/mole_brokencm.py $'def (:\n# queue.db so em comentario'; wf tests/test_mole_brokencm.py $'mole_brokencm'     # idem, mas o texto só tem comentário: sem evidência
wf lib/mole_tbare.py $'X = 1'; wf tests/test_mole_tbare.py $'from lib.mole_tbare import X\nDB = "queue.db"'
wf lib/mole_tpin.py $'X = 1'; wf tests/test_mole_tpin.py $'from lib.mole_tpin import X\nDB = "/Users/athos/shared/data/queue.db"'
wf lib/mole_big.py "# x"; { printf '# '; head -c 1100000 /dev/zero | tr '\0' x; printf '\n'; } > "$RP/lib/mole_big.py"; wf tests/test_mole_big.py $'mole_big'   # acima do teto de 1 MB de leitura: ilegível
wf lib/mole_tbare2.py $'X = 1'; wf tests/test_mole_tbare2.py $'def (:\nDB = "queue.db"\nmole_tbare2'   # teste que não parseia: texto, e o nome solto no TESTE continua sem valer
wf lib/mole_credfile.py $'P = "/etc/app/credentials_prod.json"'; wf tests/test_mole_credfile.py $'mole_credfile'
wf lib/mole_md.py $'CON = "md:analytics"'; wf tests/test_mole_md.py $'mole_md_x'   # (o teste não cita o módulo: a evidência é a do código, não a prova)
wf lib/mole_chrome.py $'PROFILE = "Library/Application Support/Google/Chrome/Default"'; wf tests/test_mole_chrome.py $'mole_chrome'
# gate-fix 1 (ga-qkc02kk): o ramo `ast` do Python acha o MESMO idioma do cofre/Mac que o ramo de texto (.sh/.js): binário com CAMINHO no argv0, constante `.local/bin/secret`, linha de shell (os.popen("secret x"), f-string),
# wrapper do repo (secret_bin() / lib.secret_cli), connect_over_cdp e run_osascript como CHAMADA, módulo do Mac, `security` com caminho e em linha de shell, banco montado em f-string. mole_prose é PROSA em string (não conta).
wf lib/mole_credpath.py $'import subprocess\ndef tok():\n    return subprocess.check_output(["/Users/athos/.local/bin/secret", "anthropic-api-key"])'; wf tests/test_mole_credpath.py $'from lib.mole_credpath import tok'
wf lib/mole_credconst.py $'from pathlib import Path\nBINARIO = Path.home() / ".local/bin/secret"'; wf tests/test_mole_credconst.py $'from lib.mole_credconst import BINARIO'
wf lib/mole_credpopen.py $'import os\nTOK = os.popen("secret motherduck-token").read()'; wf tests/test_mole_credpopen.py $'from lib.mole_credpopen import TOK'
wf lib/mole_credfstr.py $'import os\ndef tok(n):\n    return os.popen(f"secret {n}").read()'; wf tests/test_mole_credfstr.py $'from lib.mole_credfstr import tok'
wf lib/mole_credcall.py $'def cmd(n, secret_bin):\n    return [secret_bin(), n]'; wf tests/test_mole_credcall.py $'from lib.mole_credcall import cmd'
wf lib/mole_credmod.py $'import lib.secret_cli as sc\nX = sc'; wf tests/test_mole_credmod.py $'from lib.mole_credmod import X'
wf lib/mole_credpem.py $'KEY = "/etc/app/server.pem"'; wf tests/test_mole_credpem.py $'from lib.mole_credpem import KEY'   # só o CRED_FILE_RE conhece .pem
wf lib/mole_credjson.py $'P = "gdrive_credentials.json"'; wf tests/test_mole_credjson.py $'from lib.mole_credjson import P'   # prefixo no nome: o CRED_FILE_RE (começo/barra) não pega, o CRED_SHELL_RE (como o texto) pega
wf lib/mole_credsql.py $'import duckdb\ndef con():\n    c = duckdb.connect()\n    c.execute("CREATE OR REPLACE SECRET s3_x (TYPE s3, PROVIDER credential_chain, "\n              "REGION \'us-east-1\')")\n    return c'; wf tests/test_mole_credsql.py $'from lib.mole_credsql import con'   # DDL do DuckDB (lib/mds_s3.py, lib/rfb_s3.py no WA): credencial AWS; achado pelo diferencial ast x texto sobre o WA origin/main
wf lib/mole_hostcdp.py $'async def f(p):\n    return await p.chromium.connect_over_cdp("http://localhost:9222")'; wf tests/test_mole_hostcdp.py $'from lib.mole_hostcdp import f'
wf lib/mole_hostcall.py $'def f():\n    run_osascript("x")'; wf tests/test_mole_hostcall.py $'from lib.mole_hostcall import f'
wf lib/mole_hostmod.py $'import osascript\nX = 1'; wf tests/test_mole_hostmod.py $'from lib.mole_hostmod import X'
wf lib/mole_hostpath.py $'import subprocess\nsubprocess.run(["/usr/bin/security", "find-generic-password"])'; wf tests/test_mole_hostpath.py $'from lib.mole_hostpath import subprocess'
wf lib/mole_hostshell.py $'import os\nos.system("security find-generic-password -s x")'; wf tests/test_mole_hostshell.py $'from lib.mole_hostshell import os'
wf lib/mole_dbf.py $'import sqlite3\ndef c(n):\n    return sqlite3.connect(f"shared/data/{n}.db")'; wf tests/test_mole_dbf.py $'from lib.mole_dbf import c'
wf lib/mole_prose.py $'def f(n):\n    raise RuntimeError("the secret key is missing")\nX = "lib/security"\nY = "lib/secret"\nZ = "security headers are off"\nW = f"the {n} secret is missing"\nV = "setup httpfs/secret S3 falhou - leitura indisponivel"'; wf tests/test_mole_prose.py $'from lib.mole_prose import f'
wf lib/impt_macmod.py $'# impt_macmod'; wf tests/test_impt_mac_x.py $'from lib.impt_macmod import x'   # o único teste que importa impt_macmod é só-no-Mac (macs-impt.txt)
wf lib/mole_sibdb.py $'P = "shared/data/y.db"'; wf tests/test_mole_sibdb.py $'mole_sibdb'
gw add lib/mole_sibdb.py tests/test_mole_sibdb.py && gw commit -q -m "feat(wa-molp1.1): mole_sibdb" || bad "commit da irma do mole nao montado"
wf lib/mole_sibbig.py "# x"; { printf '# '; head -c 1100000 /dev/zero | tr '\0' x; printf '\n'; } > "$RP/lib/mole_sibbig.py"; wf tests/test_mole_sibbig.py $'mole_sibbig'
gw add lib/mole_sibbig.py tests/test_mole_sibbig.py && gw commit -q -m "feat(wa-molp2.1): mole_sibbig" || bad "commit da irma grande do mole nao montado"   # wa-molp2.2 herda um palpite que NÃO dá para ler (> 1 MB)   # wa-molp1.2 herda mole_sibdb pelas irmãs (palpite: só informa)
wf lib/mole_sibabs.py $'P = "/Users/athos/gt/whatsapp_automation/shared/data/y.db"'; wf tests/test_mole_sibabs.py $'mole_sibabs'   # ga-t00j8kf: palpite das irmãs com caminho absoluto (> 48 caracteres): a nota em info é cortada, a evidência não
gw add lib/mole_sibabs.py tests/test_mole_sibabs.py && gw commit -q -m "feat(wa-molp3.1): mole_sibabs" || bad "commit da irma com caminho absoluto do mole nao montado"
# teste IMPORTADOR (regra 6b): impt_target só tem teste que o IMPORTA (nome sem relação); impt_ghost só é CITADO por um teste (string, sem import); impt_jsx é requerido por um teste .cjs; impt_unparse só tem um teste que não parseia
wf lib/impt_target.py $'# impt_target'; wf tests/test_other_area.py $'from lib.impt_target import x'
wf lib/impt_ghost.py $'# impt_ghost'; wf tests/test_mentions_ghost.py $'# impt_ghost\nX = "impt_ghost"'
wf lib/impt_jsx.js $'// impt_jsx'; wf tests/area_js.cjs $'const m = require(\'../lib/impt_jsx.js\');'
wf lib/impt_unparse.py $'# impt_unparse'; wf tests/test_broken_area.py $'def (:\n# impt_unparse'
wf lib/impt_jscm.js $'// impt_jscm'; wf tests/area_jscm.cjs $'// const m = require(\'../lib/impt_jscm.js\');\n/* const n = require("../lib/impt_jscm.js"); */'   # só comentário: nenhum import de verdade
wf tests/test_imp_jscm.cjs $'// const a = require(\'../lib/imp_js_mod.js\');\n/* const b = require("../lib/imp_js_esm.mjs"); */'   # regra 8: o teste só tem require em comentário
wf lib/impt_many.py $'# impt_many'; for i in $(seq -w 1 61); do wf "tests/test_zmany_$i.py" $'from lib.impt_many import x'; done   # 61 testes importam: o teto de leitura é 60
# âncora do dado (regra 3): a bead cita só queue.db e NOMEIA o módulo. anchor_mod é limpo; anchor_out mora em shared/ (o nó não recebe); anchor_db tem "queue.db" no código
wf lib/anchor_mod.py $'# anchor_mod'; wf tests/test_anchor_mod.py $'anchor_mod'
wf shared/anchor_out.py $'# anchor_out'; wf tests/test_anchor_out.py $'anchor_out'
wf lib/anchor_db.py $'D = "queue.db"'; wf tests/test_anchor_db.py $'anchor_db'
# oráculo (ga-2hd02v.5.13, regra 9): testes que EXISTEM em origin/main e não importam nada do repo (a regra 8 lê e não acha código). orc_mole tem um banco de produção fixado no código (a regra 4 lê o teste e manda ao mini)
wf tests/test_orc_a.py $'import os\nimport pytest\n\ndef test_a():\n    assert os.sep'; wf tests/test_orc_b.py $'import json\n'; wf tests/test_orc_mole.py $'P = "shared/data/orc.db"\n'
# banco COM SCHEMA NO NÓ (ga-kzwlkhh, regra 4). sch_ok fixa shared/data/queue.db, sch_bare só tem o nome solto, sch_two/sch_att fixam um banco do recibo e um que não é, sch_md/sch_duck/sch_fstr/sch_dir são evidências que NUNCA casam (sch_abs/sch_tilde casam desde a ga-t00j8kf: caminho absoluto ou ~/ que TERMINA em shared/data/<banco do recibo>)
# com o recibo, sch_txt1/sch_txt2 são Python que não parseia (o texto tem de ver TODOS os bancos), sch_sh é shell, sch_tpin fixa o banco só no TESTE, sch_cred junta um banco do recibo com o cofre, sch_many tem 7 bancos
wf lib/sch_ok.py $'P = "shared/data/queue.db"'; wf tests/test_sch_ok.py $'from lib.sch_ok import P'; wf lib/sch_bare.py $'DB = "queue.db"'; wf tests/test_sch_bare.py $'from lib.sch_bare import DB'
wf lib/sch_two.py $'A = "shared/data/queue.db"\nB = "shared/data/outro.db"'; wf tests/test_sch_two.py $'from lib.sch_two import A'
wf lib/sch_att.py $'SQL = "ATTACH \'shared/data/queue.db\' AS a; ATTACH \'shared/data/outro.db\' AS b"'; wf tests/test_sch_att.py $'from lib.sch_att import SQL'
wf lib/sch_md.py $'A = "shared/data/queue.db"\nCON = "md:analytics"'; wf tests/test_sch_md.py $'from lib.sch_md import A'; wf lib/sch_duck.py $'D = "shared/data/analytics.duckdb"'; wf tests/test_sch_duck.py $'from lib.sch_duck import D'
wf lib/sch_abs.py $'P = "/Users/athos/gt/whatsapp_automation/shared/data/queue.db"'; wf tests/test_sch_abs.py $'from lib.sch_abs import P'; wf lib/sch_dir.py $'P = "data/queue.db"'; wf tests/test_sch_dir.py $'from lib.sch_dir import P'
wf lib/sch_fstr.py $'def c(n):\n    return f"shared/data/{n}.db"'; wf tests/test_sch_fstr.py $'from lib.sch_fstr import c'
# ga-t00j8kf: caminho ABSOLUTO (/Users/…) ou ~/ que termina em shared/data/<banco do recibo> conta como o banco do recibo. sch_tilde = ~/; sch_abs_out = banco FORA do recibo; sch_abs_dir = pasta colada ("xshared"), sch_abs_data = pasta que não é shared/data;
# sch_abs_two/sch_abs_mix = absoluto + relativo na mesma prova (todos têm de estar cobertos); sch_abs_sh = shell; sch_abs_txt = Python que não parseia (ramo de texto)
wf lib/sch_tilde.py $'P = "~/gt/whatsapp_automation/shared/data/queue.db"'; wf tests/test_sch_tilde.py $'from lib.sch_tilde import P'
wf lib/sch_abs_out.py $'P = "/Users/athos/gt/whatsapp_automation/shared/data/outro.db"'; wf tests/test_sch_abs_out.py $'from lib.sch_abs_out import P'
wf lib/sch_abs_dir.py $'P = "/Users/athos/gt/whatsapp_automation/xshared/data/queue.db"'; wf tests/test_sch_abs_dir.py $'from lib.sch_abs_dir import P'
wf lib/sch_abs_data.py $'P = "/Users/athos/gt/whatsapp_automation/data/queue.db"'; wf tests/test_sch_abs_data.py $'from lib.sch_abs_data import P'
wf lib/sch_abs_two.py $'A = "/Users/athos/gt/whatsapp_automation/shared/data/queue.db"\nB = "shared/data/outro.db"'; wf tests/test_sch_abs_two.py $'from lib.sch_abs_two import A'
wf lib/sch_abs_mix.py $'A = "/Users/athos/gt/whatsapp_automation/shared/data/queue.db"\nB = "shared/data/x.db"'; wf tests/test_sch_abs_mix.py $'from lib.sch_abs_mix import A'
wf lib/sch_abs_sh.sh $'#!/bin/sh\nsqlite3 /Users/athos/gt/whatsapp_automation/shared/data/queue.db .tables'; wf tests/test_sch_abs_sh.py $'sch_abs_sh'
wf lib/sch_abs_txt.py $'def (:\nA = "/Users/athos/gt/whatsapp_automation/shared/data/queue.db"'; wf tests/test_sch_abs_txt.py $'sch_abs_txt'
# ga-t00j8kf: a evidência de banco é guardada até 300 caracteres. sch_abs_300 = absoluto de EXATOS 300 que acaba no banco do recibo (vale); sch_abs_long = o mesmo prefixo de 300 + "/mais/y.db" (o caminho real passa de 300 e NÃO é o banco do recibo: o corte cai
# justo no fim de queue.db e, sem a marca "…", seria lido como ele)
wf lib/sch_abs_300.py "P = \"$("$PY" -I -c 'b="/Users/athos/"; t="/shared/data/queue.db"; print(b+"a"*(300-len(b)-len(t))+t)')\""; wf tests/test_sch_abs_300.py $'from lib.sch_abs_300 import P'
wf lib/sch_abs_long.py "P = \"$("$PY" -I -c 'b="/Users/athos/"; t="/shared/data/queue.db"; print(b+"a"*(300-len(b)-len(t))+t+"/mais/y.db")')\""; wf tests/test_sch_abs_long.py $'from lib.sch_abs_long import P'
wf lib/sch_txt2.py $'def (:\nA = "shared/data/queue.db"\nB = "shared/data/outro.db"'; wf tests/test_sch_txt2.py $'sch_txt2'; wf lib/sch_txt1.py $'def (:\nA = "shared/data/queue.db"'; wf tests/test_sch_txt1.py $'sch_txt1'
wf lib/sch_sh.sh $'#!/bin/sh\nsqlite3 shared/data/queue.db .tables'; wf tests/test_sch_sh.py $'sch_sh'; wf lib/sch_tpin.py $'X = 1'; wf tests/test_sch_tpin.py $'from lib.sch_tpin import X\nDB = "shared/data/x.db"'
wf lib/sch_cred.py $'import subprocess\nP = "shared/data/queue.db"\nsubprocess.run(["secret", "k"])'; wf tests/test_sch_cred.py $'from lib.sch_cred import P'
wf lib/sch_many.py "$(for i in 1 2 3 4 5 6 7; do printf 'D%s = "shared/data/m%s.db"\n' $i $i; done)"; wf tests/test_sch_many.py $'from lib.sch_many import D1'
gw add -A && gw commit -q -m 1 && gw update-ref refs/remotes/origin/main HEAD || bad "repo de mentira do WA não montado"
wf tests/test_late_mod.py "late_mod"; wf tests/test_imp_head.py "from lib.imp_alpha import x"; gw add -A && gw commit -q -m 2   # o teste de late_mod só existe no HEAD, não em origin/main
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
expect "derivado: teste citado SEM código citado não deriva nada pelo NOME (a regra 6 só vale com código citado); o teste que só cita 'foo_parser' no texto, sem import, também não ganha pela regra 8" "$(DESC 'rodar tests/auto_response/test_foo_parser_sub.py')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "derivado: teste citado SEM código citado que IMPORTA o módulo ganha pela regra 8 (ga-2hd02v.3.21), não pela 6" "$(DESC 'rodar tests/test_foo_parser.py')" 0 '"basis": "derivado", "reasons": \["prova-codigo-derivado-do-teste:1-teste\(s\)\+1-codigo\(s\)"\].*codigo-do-teste:tests/test_foo_parser\.py=lib/foo_parser\.py'
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
expect "freio: lead no texto NÃO segura mais a prova derivada (ga-2hd02v.3.21: era vocabulário, não dado) -> node; o lead fica só em info" "$(DESC 'Corrigir lib/foo_parser.py; o lead some da lista')" 0 '"verdict": "node", "basis": "derivado".*"info": \["dado-de-lead", "teste-derivado:lib/foo_parser\.py='
expect "freio: terreno, lote, construtora e proprietário no texto também não seguram" "$(DESC 'Corrigir lib/foo_parser.py: o terreno e o lote da construtora do proprietario')" 0 '"verdict": "node", "basis": "derivado"'
expect "freio: envio no texto manda ao mini" "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio: lead e envio juntos: só o envio freia (e é o único motivo)" "$(DESC 'Corrigir lib/foo_parser.py: o lead recebe o envio duplicado')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
# ga-2hd02v.5.12: o freio lê só palavra de ENVIO fora de caminho/nome (BRAKE_SEND_RE). Medido em 04/11 nas 26 beads seguradas por este freio: 12 só tinham whatsapp/chip/ban (rótulo de launchd, nome do produto, aparelho da frota), nenhuma envia nada.
FB_NODE='"verdict": "node", "basis": "derivado"'
expect "freio 5.12: whatsapp no RÓTULO de launchd (com.whatsapp.db-sync) NÃO freia -> node; a tag larga segue em info (a sombra mede com ela)" "$(DESC 'Corrigir lib/foo_parser.py; o daemon com.whatsapp.db-sync reinicia no deploy')" 0 "$FB_NODE.*\"envio-whatsapp\""
expect_not "freio 5.12: ...e a tag ESTREITA (a do freio) não aparece" "$(DESC 'Corrigir lib/foo_parser.py; o daemon com.whatsapp.db-sync reinicia no deploy')" 0 '"envio-acao"'
expect "freio 5.12: o nome do PRODUTO sozinho (WhatsApp) NÃO freia" "$(DESC 'Corrigir lib/foo_parser.py: os daemons do WhatsApp somam um nucleo de CPU')" 0 "$FB_NODE"
expect "freio 5.12: chip (aparelho da frota) e ban-… (nome de painel) NÃO freiam" "$(DESC 'Corrigir lib/foo_parser.py: o chip Business descartado e o ban-correlation-dashboard')" 0 "$FB_NODE"
expect "freio 5.12: envio dentro de rota ou nome (/api/curated/enviar-register, fila_envio) NÃO freia" "$(DESC 'Corrigir lib/foo_parser.py e a rota /api/curated/enviar-register da fila_envio')" 0 "$FB_NODE"
# controles: o que envia de verdade CONTINUA freando (o envio é irreversível; na dúvida entre falso freio e falso passe, freia)
expect "freio 5.12 (controle): envio composto com hífen (auto-enviar) AINDA freia" "$(DESC 'Corrigir lib/foo_parser.py: o responder pode auto-enviar a mensagem')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (controle): pré-envio, com acento, AINDA freia (o texto é normalizado antes)" "$(DESC 'Corrigir lib/foo_parser.py no pré-envio da cadência')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (caso real, wa-gu0l2t.6): o alerta que PODE AUTO-ENVIAR e faz o envio avulso AINDA freia" "$(DESC 'Corrigir lib/foo_parser.py; o alerta PODE AUTO-ENVIAR e faz o envio avulso')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (controle): ponto final de frase não esconde o envio" "$(DESC 'Corrigir lib/foo_parser.py, que travou o envio.')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (controle): disparo AINDA freia" "$(DESC 'Corrigir lib/foo_parser.py no disparo diario')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (controle): baileys AINDA freia" "$(DESC 'Corrigir lib/foo_parser.py na fila do baileys')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio 5.12 (controle): evolution AINDA freia" "$(DESC 'Corrigir lib/foo_parser.py na chamada da API evolution')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
# cada exclusão tem o seu caso, sem outra a proteger: `.` ANTES (rótulo que TERMINA na palavra) e `.letra` DEPOIS (palavra que COMEÇA o rótulo) são exclusões diferentes
expect "freio 5.12: envio como último segmento de um rótulo com ponto (com.envio) NÃO freia" "$(DESC 'Corrigir lib/foo_parser.py no rotulo com.envio')" 0 "$FB_NODE"
expect "freio 5.12: envio como primeiro segmento de um rótulo com ponto (envio.worker) NÃO freia" "$(DESC 'Corrigir lib/foo_parser.py e o servico envio.worker')" 0 "$FB_NODE"
expect "freio: palavras informativas que NÃO são da lista (deploy, tela) não bloqueiam a prova derivada" "$(DESC 'Corrigir lib/foo_parser.py no deploy da tela')" 0 '"basis": "derivado"'
expect "freio: sem prova derivada o lead no texto não muda o unknown (continua não sei, não vira mini)" "$(DESC 'ajustar lib/orfa_unica.py; o lead some')" 11 'sem-prova-de-codigo-e-teste'
expect "derivado: palavra mole (banco) SEM evidência no código só informa (ga-qkc02kk; a evidência é que barra, ver a seção das moles)" "$(DESC 'Corrigir lib/foo_parser.py que abre um sqlite')" 0 'prova-teste-derivado.*mole-so-em-prosa:banco-de-dados'
expect "derivado: caminho duro (código fora do filtro) ainda vence" "$(DESC 'Corrigir lib/foo_parser.py e data/helper.py')" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "derivado: .db citado como prova NÃO tira a prova derivada (ga-t05a1z9), e fica registrado" "$(DESC 'Corrigir lib/foo_parser.py e queue.db')" 0 '"basis": "derivado".*evidencia-de-dado:queue\.db'
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
expect "solto: nome solto de DADO (.json) nunca é trocado, mesmo único na árvore (agora é evidência, no nome que a bead escreveu)" "$(DESC "lib/x.py e $SOLTO_TESTE: ler solto_dado.json")" 0 '"paths": \["lib/x\.py", "tests/test_x\.py", "solto_dado\.json"\].*evidencia-de-dado:solto_dado\.json'
expect_not "solto: o nome solto de DADO não ganha nota de troca (caminho-solto:)" "$(DESC "lib/x.py e $SOLTO_TESTE: ler solto_dado.json")" 0 'caminho-solto:solto_dado'
expect "solto: código solto ganha o caminho real e, com ele, o teste derivado" "$(DESC 'ajustar solto_run.sh')" 0 '"basis": "derivado".*caminho-solto:solto_run\.sh=scripts/solto_run\.sh.*teste-derivado:scripts/solto_run\.sh=tests/test_solto_run\.py'
# nome solto de CÓDIGO que não existe em lugar nenhum da árvore (ga-2hd02v.3.22; script de diagnóstico, `part.py`): não é "código citado" para a regra 7, mas segue em `paths` e na regra 5
expect "fantasma: script de diagnóstico citado (part_diag.py, fora do repo) não impede a regra 7: o módulo nomeado deriva (node) e a nota diz o que foi ignorado" "$(DESC 'diagnostico em part_diag.py: revisar ficha_donos quando vem vazia')" 0 '"verdict": "node", "basis": "derivado".*"paths": \["part_diag\.py"\].*caminho-solto-fora-da-arvore:part_diag\.py.*caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py'
expect "fantasma: sem nome nem pai para derivar -> segue unknown (o fantasma não vira node sozinho), com a nota" "$(DESC 'diagnostico em part_diag.py da fila de busca')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-solto-fora-da-arvore:part_diag\.py"\]\}$'
expect "fantasma: nome solto que existe em 2 pastas (dupmod_x.py) não é fantasma: segue 'código citado', a regra 7 não roda, sem nota" "$(DESC 'ajustar dupmod_x.py e revisar ficha_donos')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
export WA_NODE_REPO="$T/wa-repo-ausente"
expect "solto: árvore ilegível (repo inexistente) -> segue solto (mini) COM a nota; falhou não é 'vazio'" "$(DESC "lib/x.py e $SOLTO_TESTE: ajustar loose_page.html")" 10 'caminho-fora-do-filtro:loose_page\.html.*caminho-solto-ilegivel:repo-git-rc-128'
expect "fantasma: com a árvore ilegível o nome solto NÃO é fantasma (podia ser arquivo novo da raiz): a regra 7 não roda, unknown COM a nota de ilegível" "$(DESC 'diagnostico em part_diag.py: revisar ficha_donos quando vem vazia')" 11 'sem-prova-de-codigo-e-teste.*"info": \["caminho-solto-ilegivel:repo-git-rc-128", "teste-derivado-ilegivel:repo-git-rc-128"\]\}$'
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
# cópia de backup versionada (ga-2hd02v.3.22): a derivação ignora a cópia quando existe o homônimo vivo (antes, lib.bak-*/x.py entrava, o filtro o segurava e a bead ia ao mini); só a cópia = o comportamento de antes
expect "backup: nome em lib/ e na cópia lib.bak-*/ -> deriva SÓ o vivo (node) e diz quantas cópias ignorou" "$(DESC 'revisar bak_viva_mod quando vem vazio')" 0 "$N_OK, \"reasons\": \[\"prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\)\"\].*\"info\": \[\"caminho-derivado-backup-ignorado:1\", \"caminho-derivado:nome:bak_viva_mod=lib/bak_viva_mod\.py\", \"teste-derivado:lib/bak_viva_mod\.py=tests/test_bak_viva_mod\.py\"\]\}\$"
expect "backup: só a cópia existe (nenhum homônimo vivo) -> o comportamento de antes: deriva a cópia e o filtro a segura (mini), SEM nota de ignorado" "$(DESC 'revisar so_copia_mod quando vem vazio')" 10 '"reasons": \["caminho-derivado-fora-do-filtro:daemons\.bak-20260313-200324/so_copia_mod\.py"\].*"info": \["caminho-derivado:nome:so_copia_mod=daemons\.bak-20260313-200324/so_copia_mod\.py"\]\}$'
expect "backup: a ambiguidade (mais de 3 arquivos) conta só os vivos: 2 vivos + 2 cópias derivam os 2 vivos" "$(DESC 'revisar amb_copia_mod quando vem vazio')" 0 'prova-caminho-derivado:1-teste\(s\)\+2-codigo\(s\).*"caminho-derivado-backup-ignorado:2", "caminho-derivado:nome:amb_copia_mod=daemons/amb_copia_mod\.py", "caminho-derivado:nome:amb_copia_mod=lib/amb_copia_mod\.py"'
expect "backup: archive/ também marca cópia" "$(DESC 'revisar arq_viva_mod quando vem vazio')" 0 'prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\).*"caminho-derivado-backup-ignorado:1", "caminho-derivado:nome:arq_viva_mod=lib/arq_viva_mod\.py"'
expect "backup: o commit da irmã tocou SÓ a cópia (sem homônimo vivo) -> o comportamento de antes: a cópia entra e o filtro a segura (mini)" "$(DESCI wa-par7.2 'corrigir o caso de borda')" 10 '"reasons": \["caminho-derivado-fora-do-filtro:daemons\.bak-20260313-200324/so_copia_mod\.py"\]'
expect "backup: o commit da irmã tocou o vivo E a cópia -> só o vivo entra" "$(DESCI wa-par6.2 'corrigir o caso de borda')" 0 'prova-caminho-derivado:1-teste\(s\)\+1-codigo\(s\).*"caminho-derivado-backup-ignorado:1", "caminho-derivado:irmas=lib/irma_copia_mod\.py"'
# palavras duras/moles e freios valem como sempre
expect "caminho-freio: lead no texto NÃO segura mais a prova derivada (ga-2hd02v.3.21) -> node, com a origem do caminho em info" "$(DESC 'revisar ficha_donos: o lead some da lista')" 0 '"verdict": "node", "basis": "derivado".*"info": \["dado-de-lead", "caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py"'
expect "caminho-freio: envio no texto manda ao mini" "$(DESC 'revisar ficha_donos antes de enviar a mensagem')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "caminho-freio 5.12: whatsapp no RÓTULO (com.whatsapp.painel) NÃO freia a prova por caminho derivado" "$(DESC 'revisar ficha_donos no daemon com.whatsapp.painel')" 0 '"verdict": "node", "basis": "derivado".*"caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py"'
expect "caminho: palavra mole (banco) SEM evidência no código só informa (ga-qkc02kk)" "$(DESC 'revisar ficha_donos que abre um sqlite')" 0 'prova-caminho-derivado.*mole-so-em-prosa:banco-de-dados'
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

# ---- código derivado do teste (ga-2hd02v.3.21, regra 8): a bead cita >=1 teste e NENHUM código (e a regra 7 não derivou nada) -> o código que o TESTE importa (import/require estático, lido em origin/main), pelos MESMOS filtros do citado
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
C8_OK='"verdict": "node", "basis": "derivado", "reasons": \["prova-codigo-derivado-do-teste:'
NOTA8() { printf 'sem-prova-de-codigo-e-teste.*"info": \\["codigo-do-teste-ilegivel:%s"\\]\\}$' "$1"; }
T8() { DESC "Corrigir o caso de borda; teste em $1"; }   # T8 <teste>: bead que cita só um teste (sem palavra de lead/envio/banco no texto)
expect "importa: pacote.módulo (from lib.imp_alpha import x) -> node derivado, com o par teste=código em info" "$(T8 tests/test_imp_a.py)" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\)"\].*"info": \["codigo-do-teste:tests/test_imp_a\.py=lib/imp_alpha\.py"\]\}$'
expect "importa: nome solto (import imp_alpha; lib/ está no pythonpath)" "$(T8 tests/test_imp_bare.py)" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*codigo-do-teste:tests/test_imp_bare\.py=lib/imp_alpha\.py'
expect "importa: from lib import a, b -> os dois são submódulos (e o import * não atrapalha)" "$(T8 tests/test_imp_from.py)" 0 "$C8_OK"'1-teste\(s\)\+2-codigo\(s\).*lib/imp_alpha\.py", "codigo-do-teste:tests/test_imp_from\.py=lib/imp_beta\.py"'
expect "importa: import dentro de função também conta" "$(T8 tests/test_imp_fn.py)" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*=lib/imp_beta\.py'
expect "importa: relativo (from ..lib.imp_alpha) sobe da pasta do teste" "$(T8 tests/test_imp_rel.py)" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*=lib/imp_alpha\.py'
expect "importa: dois testes que importam o mesmo módulo -> 2 testes + 1 código" "$(DESC 'Corrigir o caso de borda; testes em tests/test_imp_a.py e tests/test_imp_bare.py')" 0 "$C8_OK"'2-teste\(s\)\+1-codigo\(s\)'
expect "importa: require JS (.cjs): arquivo com extensão e pasta com index; fs e pacote npm não são do repo" "$(T8 tests/test_imp_js.cjs)" 0 "$C8_OK"'1-teste\(s\)\+2-codigo\(s\).*=lib/imp_js_dir/index\.js", "codigo-do-teste:tests/test_imp_js\.cjs=lib/imp_js_mod\.js"\]\}$'
expect "importa: import ... from './x' (.mjs)" "$(T8 tests/test_imp_esm.mjs)" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*=lib/imp_js_esm\.mjs'
expect "importa: mais de 6 pares -> 6 em info e o resto contado (codigo-do-teste-mais)" "$(T8 tests/test_imp_sete.py)" 0 "$C8_OK"'1-teste\(s\)\+7-codigo\(s\).*lib/limcap_06\.py", "codigo-do-teste-mais:1"\]\}$'
expect "custo: a regra 8 conta no derivacao_ms (>0 quando ela rodou)" "$(T8 tests/test_imp_a.py)" 0 '"custo": \{"ms": [0-9]+, "derivacao_ms": [1-9][0-9]*, "cache": "-"\}, "info"'
# vazio é legítimo: unknown SEM nota
expect "vazio: teste que só importa stdlib/pytest -> unknown SEM nota" "$(T8 tests/test_imp_stdlib.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: require/import em COMENTÁRIO de JS não é import estático -> unknown SEM nota" "$(T8 tests/test_imp_jscm.cjs)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: carga dinâmica (importlib.import_module) não é import estático -> unknown SEM nota" "$(T8 tests/test_imp_dyn.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: teste de 0 bytes lido com sucesso -> unknown SEM nota" "$(T8 tests/test_imp_vazio.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: teste que não está em origin/main (novo nesta bead) não tem o que ler -> unknown SEM nota" "$(T8 tests/test_imp_novo.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: apoio de teste (tests/imp_support.py) não é código -> unknown SEM nota" "$(T8 tests/test_imp_apoio.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "vazio: o que vale é origin/main (o import que só existe no HEAD não conta)" "$(T8 tests/test_imp_head.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA"
expect "demais: teste que importa 11 módulos do repo -> nenhum (palpite largo), com a nota" "$(T8 tests/test_imp_onze.py)" 11 'sem-prova-de-codigo-e-teste.*"info": \["codigo-do-teste-demais:11"\]\}$'
# os filtros do citado valem para o derivado
expect "filtro: o teste importa um módulo que o rsync nega (shared/) -> mini, o nó rodaria vermelho" "$(T8 tests/test_imp_fora.py)" 10 '"reasons": \["codigo-do-teste-fora-do-filtro:shared/fora_mod\.py"\]'
export WA_NODE_MAC_ONLY="$T/macs-derivado7.txt"
expect "mac-only: o teste importa um módulo só do Mac -> mini" "$(T8 tests/test_imp_mac.py)" 10 '"reasons": \["codigo-do-teste-so-no-mac:lib/mac_code_mod\.py"\]'
unset WA_NODE_MAC_ONLY
expect "freio: envio no texto manda ao mini (a prova é mais fraca que o teste+código citados)" "$(DESC 'Corrigir o envio da mensagem; teste em tests/test_imp_a.py')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "freio: lead/terreno no texto NÃO freia" "$(DESC 'Corrigir o lead do terreno; teste em tests/test_imp_a.py')" 0 "$C8_OK"
expect "freio 5.12: whatsapp/chip no texto NÃO freia a prova pelo código derivado do teste" "$(DESC 'Corrigir o chip do daemon com.whatsapp.painel; teste em tests/test_imp_a.py')" 0 "$C8_OK"
expect "mole: palavra de banco no texto, com o código que o teste importa SEM evidência, só informa (ga-qkc02kk)" "$(DESC 'Corrigir o sqlite; teste em tests/test_imp_a.py')" 0 'prova-codigo-derivado-do-teste.*mole-so-em-prosa:banco-de-dados'
expect "duro: telefone no texto ainda vence" "$(DESC 'Corrigir o caso (31) 98876-5432; teste em tests/test_imp_a.py')" 10 '"reasons": \["dado-no-texto"\]'
expect "ordem: nome snake_case que a regra 7 deriva (ficha_donos) vence a regra 8" "$(DESC 'Corrigir ficha_donos; teste em tests/test_imp_a.py')" 0 '"reasons": \["prova-caminho-derivado:'
expect "ordem: teste + código citados -> a regra 5 (basis text); a 8 nem roda" "$(DESC 'Corrigir lib/foo_parser.py; teste em tests/test_imp_a.py')" 0 '"basis": "text".*prova-no-texto:1-teste\(s\)\+1-codigo'
# falhou/ilegível: unknown COM a nota (nunca node, nunca o mesmo resultado do vazio)
expect "ilegível: teste que não parseia -> unknown com a nota" "$(T8 tests/test_imp_quebrado.py)" 11 "$(NOTA8 teste-nao-parseia)"
expect "ilegível: teste de mais de 1 MB não é lido -> unknown com a nota" "$(T8 tests/test_imp_grande.py)" 11 "$(NOTA8 teste-grande)"
stub git-show-quebra 'for a in "$@"; do [ "$a" = show ] && exit 2; done; exec git "$@"'   # só o `git show` falha (rc 2)
stub git-show-lento 'for a in "$@"; do [ "$a" = show ] && sleep 6; done; exec git "$@"'
export WA_NODE_GIT="$T/git-show-quebra"; expect "ilegível: git show que falha (rc 2) -> unknown com a nota, nunca 'teste sem import'" "$(T8 tests/test_imp_a.py)" 11 "$(NOTA8 teste-git-rc-2)"; unset WA_NODE_GIT
export WA_NODE_GIT="$T/git-show-lento" WA_NODE_REPO_TIMEOUT=1; expect "ilegível: git show que não responde no prazo -> unknown com a nota" "$(T8 tests/test_imp_a.py)" 11 "$(NOTA8 teste-git-sem-resposta)"; unset WA_NODE_GIT WA_NODE_REPO_TIMEOUT
export WA_NODE_REPO="$T/wa-repo-ausente"; expect "ilegível: repo inexistente -> unknown com a nota (não 'nada importado')" "$(T8 tests/test_imp_a.py)" 11 "$(NOTA8 repo-git-rc-128)"; export WA_NODE_REPO="$RP"
# a regra 7 que NÃO CONSEGUIU LER não é "a regra 7 não derivou nada": com teste citado, a regra 8 NÃO pode correr atrás dela (o git log das irmãs que falhou podia ter o código e o freio dele) -> unknown com a nota da regra 7, nunca node
R7Q="Corrigir o caso de borda; teste em tests/test_imp_a.py"   # bead COM PAI (wa-par1.2 -> irmãs wa-par1.*) e um teste citado que importa lib.imp_alpha
export WA_NODE_CACHE="$T/cache-r8p"   # o caso legível GRAVA o cache das irmãs; ele tem pasta própria para o cache das falhas (abaixo) seguir sem arquivo
expect "r7 lê: irmãs legíveis + teste citado -> a regra 7 vence (prova-caminho-derivado), a 8 nem roda" "$(DESCI wa-par1.2 "$R7Q")" 0 '"reasons": \["prova-caminho-derivado:'
export WA_NODE_CACHE="$T/cache-r8q"   # nunca gravado (a falha do git não grava): um cache válido das irmãs esconderia a falha
export WA_NODE_GIT="$T/git-log-quebra"; expect "r7 falha + teste citado: git log das irmãs com rc 2 -> unknown com a nota da regra 7; a regra 8 NÃO decide (antes: node pelo import do teste)" "$(DESCI wa-par1.2 "$R7Q")" 11 "$(NOTA7 irmas-git-rc-2)"; unset WA_NODE_GIT
export WA_NODE_GIT="$T/git-log-lento" WA_NODE_SIBLING_TIMEOUT=1; expect "r7 falha + teste citado: git log das irmãs sem resposta no prazo -> unknown com a nota da regra 7, sem regra 8" "$(DESCI wa-par1.2 "$R7Q")" 11 "$(NOTA7 irmas-git-sem-resposta)"; unset WA_NODE_GIT WA_NODE_SIBLING_TIMEOUT
[ ! -e "$T/cache-r8q" ] && ok "r7 falha + teste citado: a falha do git não gravou cache" || bad "r7 falha + teste citado: a falha do git gravou cache"
export WA_NODE_CACHE="$T/cache"
expect "r7 sem pai: sem irmãs para ler a regra 7 não falha, e a 8 corre (o git log quebrado nem é chamado)" "$(DESC "$R7Q")" 0 "$C8_OK"
# teste citado que a regra 8 não lê (novo nesta bead, ausente de origin/main) não conta no N-teste(s) e é nomeado em info
expect "r8: teste citado que não foi lido (novo) é nomeado em info; o motivo conta só o que provou" "$(DESC 'Corrigir o caso de borda; testes em tests/test_imp_a.py e tests/test_imp_novo.py')" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*"codigo-do-teste:tests/test_imp_a\.py=lib/imp_alpha\.py", "teste-nao-lido:tests/test_imp_novo\.py"\]\}$'
expect "r8: mais de 3 testes não lidos -> 3 nomeados e o resto contado (teste-nao-lido-mais)" "$(DESC 'Corrigir o caso de borda; testes em tests/test_imp_a.py, tests/test_n1.py, tests/test_n2.py, tests/test_n3.py e tests/test_n4.py')" 0 "$C8_OK"'1-teste\(s\)\+1-codigo\(s\).*"teste-nao-lido:tests/test_n1\.py", "teste-nao-lido:tests/test_n2\.py", "teste-nao-lido:tests/test_n3\.py", "teste-nao-lido-mais:1"\]\}$'
export WA_NODE_REPO="$T/wa-repo-ausente" WA_NODE_MIRROR="$T/espelho-ausente"

# ---- oráculo = teste vermelho em main (ga-2hd02v.5.13, regra 9 / A1): BUG que cita >=1 teste (que existe em origin/main), nenhum código (as regras 7 e 8 LERAM e não derivaram nada) e DIZ que o teste reprova/falha/está vermelho em main -> o
# teste vermelho é o oráculo: node, basis `derivado`. Os 6 casos positivos usam o texto das 6 beads WA reais (wa-9b70jk, wa-appaph, wa-jzaa2w, wa-kjwmcv, wa-sb1jyl, wa-xy301a) com os nomes de teste trocados pelos do repo de mentira.
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
C9_OK='"verdict": "node", "basis": "derivado", "reasons": \["prova-oraculo-teste-vermelho:'
U9='"verdict": "unknown", "basis": "", "reasons": \["sem-prova-de-codigo-e-teste"\]'
DESCB() { printf '{"id":"wa-t9","title":"t","issue_type":"bug","description":"%s"}' "$1"; }                              # DESCB <texto>: bug
DESCBT() { printf '{"id":"wa-t9","title":"%s","issue_type":"bug","description":"%s"}' "$1" "$2"; }                      # DESCBT <título> <texto>: bug com título (a palavra vermelha às vezes está nele)
DESCBI() { printf '{"id":"%s","title":"t","issue_type":"bug","description":"%s"}' "$1" "$2"; }                          # DESCBI <id> <texto>: bug com id explícito (o das irmãs vem do id)
DESCTY() { printf '{"id":"wa-t9","title":"t","issue_type":"%s","description":"%s"}' "$1" "$2"; }                        # DESCTY <tipo> <texto>
O9_9B70JK="$(DESCBT 'Teste y52af0 test_quadradinhos_voltam_para_cima_do_lote reprova em main: não conhece a camada celulas-lote-line (f24163488)' 'Pré-existente em main (visto em 25/10 durante a wa-qb10p3): tests/test_orc_a.py:628 espera a lista logo depois do pbh-fill, mas desde f24163488 a pilha tem celulas-lote-line no meio. Conserto provável: atualizar a lista esperada no teste.')"
O9_APPAPH="$(DESCBT 'Teste e2e affr0: selo de saldo estoura a largura da tabela de Proprietários em 375px' 'Achado em wa-qb10p3 (25/10): tests/test_orc_a.py::test_o_selo_de_saldo_cabe_na_linha_da_tabela_sem_rolagem_horizontal[375] FALHA também em origin/main 19bd9cb66 (não é do qb10p3). Medir se é regressão real de layout no celular ou teste desatualizado.')"
O9_JZAA2W="$(DESCBT '12 testes de Chromium vermelhos na main: casa (rv1qkk43, 11) ficou velha + 1 de layout do affr0 [375]' '12 testes de Chromium estão VERMELHOS na main (medido em 03/11 contra c8990da7f, sem nenhuma mudança minha) e ninguém os acusou. Quais: tests/test_orc_a.py (11 testes test_casa_) e tests/test_orc_b.py::test_o_selo_de_saldo_cabe[375] (causa NÃO investigada).')"
O9_KJWMCV="$(DESCBT 'Teste quebrado no main: test_faixa_da_ficha_na_tela_real procura Vendido para construtora na linha Estado do lote, que saiu da ficha em 12/10' 'Medido 22/10 por thies: tests/test_orc_a.py::test_faixa_da_ficha_na_tela_real[computador-1280|celular-390] reprova no origin/main e também ANTES da wa-2ifrhk.1. Conserto: decidir onde o Estado do lote mora hoje e atualizar o teste. Não é regressão nova.')"
O9_SB1JYL="$(DESCBT '4 testes do mapa vermelhos em main sem dono: REG_VIVO não definido nos arnês (3) + ficha diretriz (1)' '4 testes do mapa estão vermelhos em main (base 1df200427) e nenhuma bead aberta é dona deles: tests/test_orc_a.py::test_resposta_ok e tests/test_orc_b.py::test_cenario[recarga]. Causa provável: templates/map_viewer.html cria REG_VIVO e os arnês não o declaram.')"
O9_XY301A="$(DESCBT 'Teste de tela do mapa falha com a máquina carregada: prazo de 800 ms estoura antes da 1ª leitura' 'tests/test_orc_a.py::test_mapa_que_nao_responde le o texto esperando Carregando, mas com load 64 a página leva mais que o prazo. Falha igual com o template do origin/main (medido por batista na wa-2msnb5.1) — não é regressão.')"
expect "oráculo: wa-9b70jk (reprova em main no título; teste com :linha) -> node derivado, o teste é a prova" "$O9_9B70JK" 0 "$C9_OK"'1-teste\(s\)"\].*"tests": \["tests/test_orc_a\.py"\]'
expect "oráculo: wa-appaph (FALHA também em origin/main; id de pytest com [375])" "$O9_APPAPH" 0 "$C9_OK"'1-teste\(s\)"\]'
expect "oráculo: wa-jzaa2w (VERMELHOS na main, maiúsculas; 2 testes citados) -> 2-teste(s)" "$O9_JZAA2W" 0 "$C9_OK"'2-teste\(s\)"\]'
expect "oráculo: wa-kjwmcv (quebrado no main + reprova no origin/main; |celular no id)" "$O9_KJWMCV" 0 "$C9_OK"'1-teste\(s\)"\]'
expect "oráculo: wa-sb1jyl (vermelhos em main; 2 testes e um .html que não é código nem teste)" "$O9_SB1JYL" 0 "$C9_OK"'2-teste\(s\)"\]'
expect "oráculo: wa-xy301a (a falha está no título e na frase do origin/main; 'não é regressão' DEPOIS não nega)" "$O9_XY301A" 0 "$C9_OK"'1-teste\(s\)"\]'
# cada palavra vermelha, sozinha
expect "oráculo: palavra «reprova»" "$(DESCB 'tests/test_orc_a.py reprova em main')" 0 "$C9_OK"
expect "oráculo: palavra «falha»" "$(DESCB 'tests/test_orc_a.py falha em main')" 0 "$C9_OK"
expect "oráculo: palavra «vermelho»" "$(DESCB 'tests/test_orc_a.py está vermelho em main')" 0 "$C9_OK"
expect "oráculo: palavra «quebrado»" "$(DESCB 'tests/test_orc_a.py ficou quebrado em main')" 0 "$C9_OK"
expect "oráculo: palavra «fails» (inglês)" "$(DESCB 'tests/test_orc_a.py fails in origin/main')" 0 "$C9_OK"
# o oráculo é do BUG que DIZ que o teste está vermelho em main; sem isso a bead segue unknown, SEM nota (vazio é legítimo)
expect "oráculo não vale para TAREFA (wa-jhblfa: achados do gate pedem testes novos)" "$(DESCTY task 'tests/test_orc_a.py reprova em main')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale sem a palavra vermelha perto do main («falha silenciosa» de outra coisa)" "$(DESCB 'Os achados fecham os buracos de falha silenciosa que a feature deixou; tests/test_orc_a.py cobre o caso')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale se o vermelho e o main estão em frases diferentes" "$(DESCB 'A falha silenciosa do sync. Depois do merge em main a ordem muda; tests/test_orc_a.py cobre o caso')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale com negação colada («não reprova em main»)" "$(DESCB 'tests/test_orc_a.py não reprova em main; o problema aparece só no tablet')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale se a mesma frase diz que passa em main" "$(DESCB 'tests/test_orc_a.py passa em main mas falha no tablet')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale para «main thread» (não é a branch)" "$(DESCB 'tests/test_orc_a.py falha na main thread do worker')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale para «main()» (a função, não a branch)" "$(DESCB 'tests/test_orc_a.py falha em main() do worker')" 11 "$U9.*$SEMNOTA"
expect "oráculo não vale sem teste citado (nada que reproduzir)" "$(DESCB 'O teste do modulo reprova em main')" 11 "$U9.*$SEMNOTA"
# teste citado que NÃO está em origin/main não pode estar vermelho «em main»: unknown, e a nota nomeia o teste (até 3)
expect "oráculo: teste que não está em origin/main (novo) -> unknown com a nota" "$(DESCB 'tests/test_orc_novo.py reprova em main')" 11 "$U9"'.*"info": \["oraculo-teste-fora-de-main:tests/test_orc_novo\.py"\]\}$'
expect "oráculo: UM dos testes citados ausente de main basta para não provar nada" "$(DESCB 'tests/test_orc_a.py e tests/test_orc_novo.py reprovam em main')" 11 "$U9"'.*"info": \["oraculo-teste-fora-de-main:tests/test_orc_novo\.py"\]\}$'
expect "oráculo: mais de 3 testes ausentes -> 3 nomeados e o resto contado" "$(DESCB 'tests/test_orc_a.py, tests/test_n1.py, tests/test_n2.py, tests/test_n3.py e tests/test_n4.py reprovam em main')" 11 "$U9"'.*"oraculo-teste-fora-de-main:tests/test_n1\.py", "oraculo-teste-fora-de-main:tests/test_n2\.py", "oraculo-teste-fora-de-main:tests/test_n3\.py", "oraculo-teste-fora-de-main-mais:1"\]\}$'
# os freios e a ordem das regras não mudam
expect "freio: envio no texto manda o oráculo ao mini (a prova é mais fraca que o teste+código citados)" "$(DESCB 'Corrigir o envio da mensagem: tests/test_orc_a.py reprova em main')" 10 '"reasons": \["freio-derivado:envio-acao"\]'
expect "mole: o teste vermelho com banco de produção fixado no código vai ao mini (a regra 4 lê o teste)" "$(DESCB 'tests/test_orc_mole.py reprova em main')" 10 'moles:banco-de-dados'
expect "duro: telefone no texto vence o oráculo" "$(DESCB 'Cliente (31) 98876-5432: tests/test_orc_a.py reprova em main')" 10 '"reasons": \["dado-no-texto"\]'
expect "ordem: código + teste citados -> a regra 5 (basis text); o oráculo nem roda" "$(DESCB 'lib/foo_parser.py: tests/test_orc_a.py reprova em main')" 0 '"basis": "text".*prova-no-texto:1-teste\(s\)\+1-codigo'
expect "ordem: o teste importa código do repo -> a regra 8 vence o oráculo" "$(DESCB 'tests/test_imp_a.py reprova em main')" 0 '"reasons": \["prova-codigo-derivado-do-teste:'
expect "ordem: o teste importa módulos demais (regra 8 diz «demais») -> unknown, o oráculo não passa por cima" "$(DESCB 'tests/test_imp_onze.py reprova em main')" 11 'sem-prova-de-codigo-e-teste.*"info": \["codigo-do-teste-demais:11"\]\}$'
export WA_NODE_CACHE="$T/cache-orp"   # o caso legível GRAVA o cache das irmãs; o das falhas (abaixo) tem pasta própria e nunca é gravado
expect "ordem: irmãs legíveis derivam código -> a regra 7 vence o oráculo" "$(DESCBI wa-par1.2 'tests/test_orc_a.py reprova em main')" 0 '"reasons": \["prova-caminho-derivado:'
# falhou/ilegível: o oráculo NÃO roda atrás de uma leitura que falhou (nunca node, nunca o mesmo resultado do vazio)
expect "ilegível: o teste não parseia (regra 8 falhou) -> unknown com a nota da regra 8; o oráculo não decide" "$(DESCB 'tests/test_imp_quebrado.py reprova em main')" 11 "$(NOTA8 teste-nao-parseia)"
export WA_NODE_REPO="$T/wa-repo-ausente"; expect "ilegível: repo inexistente -> unknown com a nota da regra 8, nunca node pelo oráculo" "$(DESCB 'tests/test_orc_a.py reprova em main')" 11 "$(NOTA8 repo-git-rc-128)"; export WA_NODE_REPO="$RP"
export WA_NODE_CACHE="$T/cache-orq"   # nunca gravado (a falha do git não grava): um cache válido das irmãs esconderia a falha
export WA_NODE_GIT="$T/git-log-quebra"; expect "ilegível: git log das irmãs com rc 2 (regra 7 falhou) -> unknown com a nota da regra 7; o oráculo não decide" "$(DESCBI wa-par1.2 'tests/test_orc_a.py reprova em main')" 11 "$(NOTA7 irmas-git-rc-2)"; unset WA_NODE_GIT
[ ! -e "$T/cache-orq" ] && ok "ilegível: a falha do git das irmãs não gravou cache" || bad "ilegível: a falha do git das irmãs gravou cache"
export WA_NODE_CACHE="$T/cache"
# ---- ga-v8p1tx.1.3: bug/feature LIBERAM o freio de envio nas provas derivadas das regras 6, 6b, 7 e 8 (a palavra só informa: `envio-acao` + `envio-liberado:<tipo>` em info); task, chore, tipo ausente ou ilegível seguem freando;
# o oráculo (regra 9) mantém o freio; as moles (regra 4) e as regras duras valem DEPOIS da liberação. Medido em 14/11 nas 349 beads WA (runbook hetzner-wa-node.md, «Medido em 14/11»): das 24 freadas, 14 são bug/feature (4 viram node,
# 10 caem nas moles) e 10 são task (seguem freadas: operação em aparelho de produção, mudança de infra, decisão de produto, análise).
FREE_TXT='Corrigir lib/foo_parser.py antes de enviar a mensagem'
TYPED() { field "$(DESC "$1")" issue_type "\"$2\""; }   # TYPED <texto> <tipo>: a bead do DESC com `issue_type`
FS_BRAKE='"reasons": \["freio-derivado:envio-acao"\]'
expect "liberado 1.3 (regra 6): bug com palavra de envio NÃO é freado -> node derivado; a palavra e o tipo ficam em info" "$(TYPED "$FREE_TXT" bug)" 0 "$FB_NODE"'.*"info": \["envio-whatsapp", "envio-acao", "envio-liberado:bug", "teste-derivado:lib/foo_parser\.py='
expect "liberado 1.3 (regra 6): feature também é liberada" "$(TYPED "$FREE_TXT" feature)" 0 "$FB_NODE"'.*"envio-acao", "envio-liberado:feature"'
expect "liberado 1.3 (controle): task com a MESMA palavra segue freada (é onde moram as operações)" "$(TYPED "$FREE_TXT" task)" 10 "$FS_BRAKE"
expect_not "liberado 1.3 (controle): ...e a task não leva a tag de liberação" "$(TYPED "$FREE_TXT" task)" 10 'envio-liberado'
expect "liberado 1.3 (controle): chore segue freado" "$(TYPED "$FREE_TXT" chore)" 10 "$FS_BRAKE"
expect "liberado 1.3 (controle): sem issue_type segue freado (todos os casos antigos de freio são assim)" "$(DESC "$FREE_TXT")" 10 "$FS_BRAKE"
expect "liberado 1.3 (controle): issue_type vazio segue freado" "$(TYPED "$FREE_TXT" '')" 10 "$FS_BRAKE"
expect "liberado 1.3 (controle): o tipo é comparado como está (Bug com maiúscula não libera: tipo desconhecido freia, a mesma regra do estado inerte)" "$(TYPED "$FREE_TXT" Bug)" 10 "$FS_BRAKE"
expect "liberado 1.3 (controle): issue_type que não é texto (lista) segue freado e não derruba o classificador" "$(field "$(DESC "$FREE_TXT")" issue_type '["bug"]')" 10 "$FS_BRAKE"
expect_not "liberado 1.3: sem palavra de envio a tag de liberação não aparece (bug sem envio = o caminho de sempre)" "$(TYPED 'Corrigir lib/foo_parser.py quando a entrada vem vazia.' bug)" 0 'envio-liberado'
expect "liberado 1.3 (regra 6b): bug liberado também na prova pelo teste IMPORTADOR" "$(TYPED 'ajustar lib/impt_target.py e o envio por whatsapp' bug)" 0 "$FB_NODE"'.*"envio-liberado:bug".*teste-importador:lib/impt_target\.py'
expect "liberado 1.3 (regra 7): bug liberado na prova por NOME do módulo (ficha_donos) -> node, com a origem do caminho em info" "$(TYPED 'revisar ficha_donos antes de enviar a mensagem' bug)" 0 "$FB_NODE"'.*"envio-liberado:bug".*"caminho-derivado:nome:ficha_donos=lib/ficha_donos\.py"'
expect "liberado 1.3 (regra 7, controle): a mesma bead como task segue freada" "$(TYPED 'revisar ficha_donos antes de enviar a mensagem' task)" 10 "$FS_BRAKE"
expect "liberado 1.3 (regra 8): bug liberado na prova pelo código que o teste citado IMPORTA -> node" "$(TYPED 'Corrigir o envio da mensagem; teste em tests/test_imp_a.py' bug)" 0 "$FB_NODE"'.*"envio-liberado:bug".*codigo-do-teste:tests/test_imp_a\.py=lib/imp_alpha\.py'
expect "liberado 1.3 (regra 8, controle): a mesma bead como task segue freada" "$(TYPED 'Corrigir o envio da mensagem; teste em tests/test_imp_a.py' task)" 10 "$FS_BRAKE"
# o oráculo (regra 9) NÃO libera: a prova dele é só o que o texto afirma, e toda bead dele é bug. A tag de liberação aparece em info (o texto tem a palavra e o tipo é bug), mas quem freia ignora
expect "liberado 1.3 (regra 9): o oráculo segue freando o bug com palavra de envio (a liberação não vaza para ele)" "$(DESCB 'Corrigir o envio da mensagem: tests/test_orc_a.py reprova em main')" 10 "$FS_BRAKE"'.*"envio-liberado:bug"'
# a liberação só tira o freio de PALAVRA: o resto do caminho vale como sempre
expect "liberado 1.3 + moles: bug com palavra de envio liberado mas com evidência de credencial no código da prova vai ao mini pelas moles" "$(TYPED 'ajustar lib/mole_cred.py antes de enviar a mensagem' bug)" 10 'moles:credencial.*mole-evidencia:credencial=lib/mole_cred\.py\[argv:secret\]'
expect "liberado 1.3 + duro: caminho que o filtro segura vence a liberação" "$(TYPED 'Corrigir lib/foo_parser.py e data/helper.py antes de enviar a mensagem' bug)" 10 'caminho-fora-do-filtro:data/helper\.py'
expect "liberado 1.3 + duro: telefone no texto vence a liberação" "$(TYPED 'Corrigir lib/foo_parser.py antes de enviar ao (31) 98876-5432' bug)" 10 '"reasons": \["dado-no-texto"\]'
expect "liberado 1.3 + etiqueta: node:mini (decisão humana) vence a liberação" "$(labels "$(TYPED "$FREE_TXT" bug)" '["node:mini"]')" 10 '"reasons": \["etiqueta-node:mini"\]'
export WA_NODE_REPO="$T/wa-repo-ausente" WA_NODE_MIRROR="$T/espelho-ausente"

# ---- moles por EVIDÊNCIA (ga-qkc02kk, regra 4): a palavra mole escrita na bead é PROSA; quem decide é o CÓDIGO dos arquivos de prova, lido em origin/main. Três estados: leu e achou -> `moles:` (mesmo sem palavra); leu e não achou -> a
# palavra só informa (`mole-so-em-prosa:`); NÃO consegui ler / nada existente para ler -> volta a palavra (`mole-ilegivel:` / `mole-sem-arquivo-lido`). node:ok, PII, freio de envio e node:mini seguem como eram.
export WA_NODE_REPO="$RP" WA_NODE_MIRROR="$T/mirror-ok"
ME='"verdict": "node", "basis": "derivado"'
expect "mole: palavras de banco/credencial/host SEM evidência no código (docstring e comentário não contam; connect(variável) não conta) NÃO barram: node + info" "$(DESC 'ajustar lib/mole_clean.py que abre um sqlite com o token e roda osascript')" 0 "$ME.*mole-so-em-prosa:banco-de-dados\", \"mole-so-em-prosa:credencial\", \"mole-so-em-prosa:host-mac"
expect "mole: prova no texto (código+teste citados) também passa pelo portão: sem evidência, a palavra só informa (e o nome solto \"queue.db\" no TESTE não é banco de produção)" "$(DESC 'lib/mole_clean.py abre um sqlite; tests/test_mole_clean.py')" 0 '"verdict": "node", "basis": "text".*mole-so-em-prosa:banco-de-dados'
expect "mole: evidência vence SEM palavra nenhuma - nome de banco solto no código (\"queue.db\", o WA monta o caminho por pedaços)" "$(DESC 'ajustar lib/mole_db.py')" 10 'moles:banco-de-dados.*mole-evidencia:banco-de-dados=lib/mole_db\.py\[queue\.db\]'
expect "mole: evidência - caminho de produção fixado (shared/data/x.db)" "$(DESC 'ajustar lib/mole_pin.py')" 10 'moles:banco-de-dados.*\[shared/data/x\.db\]'
expect "mole: evidência - argv do cofre (\"secret\")" "$(DESC 'ajustar lib/mole_cred.py')" 10 'moles:credencial.*mole-evidencia:credencial=lib/mole_cred\.py\[argv:secret\]'
expect "mole: evidência - chamada _secret(...)" "$(DESC 'ajustar lib/mole_credfn.py')" 10 'moles:credencial.*\[_secret\(\)\]'
expect "mole: evidência - osascript no argv" "$(DESC 'ajustar lib/mole_host.py')" 10 'moles:host-mac.*mole-evidencia:host-mac=lib/mole_host\.py\[argv:osascript\]'
expect "mole: evidência - \"security\" sozinho no argv (só a lista de executáveis pega)" "$(DESC 'ajustar lib/mole_secarg.py')" 10 'moles:host-mac.*\[argv:security\]'
expect "mole: evidência em .sh (texto, sem as linhas de comentário) - launchctl" "$(DESC 'ajustar lib/mole_shhost.sh')" 10 'moles:host-mac.*mole_shhost\.sh\[launchctl\]'
expect "mole: evidência em .js - osascript" "$(DESC 'ajustar lib/mole_jshost.js')" 10 'moles:host-mac.*mole_jshost\.js\[osascript\]'
expect "mole: Python que não parseia lê o TEXTO (mais largo) e acha o banco" "$(DESC 'ajustar lib/mole_broken.py')" 10 'moles:banco-de-dados.*mole_broken\.py\[queue\.db\]'
expect "mole: caminho de produção FIXADO no teste (/Users/…/queue.db) também é evidência" "$(DESC 'ajustar lib/mole_tpin.py')" 10 'moles:banco-de-dados.*tests/test_mole_tpin\.py'
expect_not "mole: \`import secrets\` (stdlib, números aleatórios) NÃO é cofre" "$(DESC 'ajustar lib/mole_stdsec.py')" 0 'moles:|mole-evidencia'
expect_not "mole: variável de ambiente com nome de token NÃO é evidência (o teste a substitui)" "$(DESC 'ajustar lib/mole_envtok.py')" 0 'moles:|mole-evidencia'
expect_not "mole: \`/Users/…\` sozinho NÃO é recurso do host (é caminho-padrão)" "$(DESC 'ajustar lib/mole_users.py')" 0 'moles:|mole-evidencia'
expect_not "mole: .sh que só cita launchctl em COMENTÁRIO não tem evidência" "$(DESC 'ajustar lib/mole_shclean.sh')" 0 'moles:|mole-evidencia'
expect_not "mole: Python que não parseia e só tem comentário não tem evidência" "$(DESC 'ajustar lib/mole_brokencm.py')" 0 'moles:|mole-evidencia'
expect_not "mole: nome de banco solto no TESTE (o teste cria o seu em tmp) NÃO conta" "$(DESC 'ajustar lib/mole_tbare.py')" 0 'moles:|mole-evidencia'
expect "mole: node:ok é decisão humana e continua ignorando as moles (mesmo com evidência no código e com a palavra no texto)" "$(labels "$(DESC 'ajustar lib/mole_db.py que abre um sqlite')" '["node:ok"]')" 0 '"basis": "label".*moles-ignoradas:banco-de-dados'
expect "mole: evidência - arquivo de credencial (credentials_prod.json)" "$(DESC 'ajustar lib/mole_credfile.py')" 10 'moles:credencial.*credentials_prod\.json'
expect "mole: evidência - conexão MotherDuck (md:...)" "$(DESC 'ajustar lib/mole_md.py e tests/test_mole_md.py')" 10 'moles:banco-de-dados.*\[md:analytics\]'
expect "mole: evidência - perfil do Chrome do Mac" "$(DESC 'ajustar lib/mole_chrome.py')" 10 'moles:host-mac.*Application Support/Google/Chrome'
expect "mole: evidência - binário do cofre com CAMINHO no argv0 (/Users/…/.local/bin/secret), o idioma mais comum do WA" "$(DESC 'ajustar lib/mole_credpath.py')" 10 'moles:credencial.*mole-evidencia:credencial=lib/mole_credpath\.py\[argv:secret\]'
expect "mole: evidência - constante com .local/bin/secret (Path.home() / \".local/bin/secret\")" "$(DESC 'ajustar lib/mole_credconst.py')" 10 'moles:credencial.*mole_credconst\.py\[argv:secret\]'
expect "mole: evidência - linha de shell os.popen(\"secret motherduck-token\")" "$(DESC 'ajustar lib/mole_credpopen.py')" 10 'moles:credencial.*mole_credpopen\.py\[sh:secret motherduck-token\]'
expect "mole: evidência - f-string os.popen(f\"secret {n}\") (o pedaço dinâmico vira palavra)" "$(DESC 'ajustar lib/mole_credfstr.py')" 10 'moles:credencial.*mole_credfstr\.py\[sh:secret _\]'
expect "mole: evidência - arquivo de chave (.pem)" "$(DESC 'ajustar lib/mole_credpem.py')" 10 'moles:credencial.*mole_credpem\.py\[server\.pem\]'
expect "mole: evidência - arquivo de credencial com prefixo no nome (gdrive_credentials.json), como o ramo de texto acha" "$(DESC 'ajustar lib/mole_credjson.py')" 10 'moles:credencial.*mole_credjson\.py\[sh:credentials\.json\]'
expect "mole: evidência - DDL do DuckDB CREATE OR REPLACE SECRET … credential_chain (credencial AWS; strings adjacentes)" "$(DESC 'ajustar lib/mole_credsql.py')" 10 'moles:credencial.*mole_credsql\.py\[sh:CREATE OR REPLACE SECRET\]'
expect "mole: evidência - chamada ao wrapper do repo secret_bin()" "$(DESC 'ajustar lib/mole_credcall.py')" 10 'moles:credencial.*mole_credcall\.py\[secret_bin\(\)\]'
expect "mole: evidência - módulo do wrapper do repo (lib.secret_cli)" "$(DESC 'ajustar lib/mole_credmod.py')" 10 'moles:credencial.*mole_credmod\.py\[import lib\.secret_cli\]'
expect "mole: evidência - connect_over_cdp(...) como CHAMADA (o HOST_RE de string não vê nome de função)" "$(DESC 'ajustar lib/mole_hostcdp.py')" 10 'moles:host-mac.*mole_hostcdp\.py\[connect_over_cdp\(\)\]'
expect "mole: evidência - run_osascript(...) como chamada (nome com _ ao redor)" "$(DESC 'ajustar lib/mole_hostcall.py')" 10 'moles:host-mac.*mole_hostcall\.py\[run_osascript\(\)\]'
expect "mole: evidência - módulo do Mac (import osascript)" "$(DESC 'ajustar lib/mole_hostmod.py')" 10 'moles:host-mac.*mole_hostmod\.py\[import osascript\]'
expect "mole: evidência - /usr/bin/security com CAMINHO no argv0" "$(DESC 'ajustar lib/mole_hostpath.py')" 10 'moles:host-mac.*mole_hostpath\.py\[argv:security\]'
expect "mole: evidência - linha de shell \"security find-generic-password …\"" "$(DESC 'ajustar lib/mole_hostshell.py')" 10 'moles:host-mac.*mole_hostshell\.py\[security find-generic-password\]'
expect "mole: evidência - banco montado em f-string (shared/data/{n}.db)" "$(DESC 'ajustar lib/mole_dbf.py')" 10 'moles:banco-de-dados.*mole_dbf\.py\[shared/data/_\.db\]'
expect_not "mole: PROSA em string (\"the secret key is missing\", \"httpfs/secret S3 falhou\", \"lib/security\", \"lib/secret\", \"security headers are off\", f\"the {n} secret is missing\") NÃO é evidência" "$(DESC 'ajustar lib/mole_prose.py')" 0 'moles:|mole-evidencia'
expect_not "mole: nome de banco solto num TESTE que não parseia (texto) também não conta" "$(DESC 'ajustar lib/mole_tbare2.py')" 0 'moles:|mole-evidencia'
# três estados: não consegui ler / nada para ler -> a palavra volta a valer (como antes), e a resposta diz por quê
export WA_NODE_REPO="$T/wa-repo-ausente"
expect "mole: repo ilegível + palavra -> a palavra vale (mini) e a leitura que falhou é nomeada" "$(DESC 'lib/mole_clean.py abre um sqlite; tests/test_mole_clean.py')" 10 'moles:banco-de-dados.*"mole-ilegivel:repo-git-rc-128"'
expect "mole: repo ilegível SEM palavra -> node como antes, mas o info NÃO esconde que a varredura não rodou (\"não li\" != \"li e não achei\")" "$(DESC 'lib/mole_clean.py e tests/test_mole_clean.py')" 0 '"verdict": "node", "basis": "text".*"mole-ilegivel:repo-git-rc-128"'
export WA_NODE_REPO="$RP"
expect "mole: todos os arquivos da prova são NOVOS + palavra -> não há o que ler, a palavra vale" "$(DESC 'lib/novo_zz.py abre um sqlite; tests/test_novo_zz.py')" 10 'moles:banco-de-dados.*"mole-sem-arquivo-lido"'
expect "mole: um arquivo existente limpo + um NOVO + palavra -> node (o novo não tem o que ler e não bloqueia; o nó o constrói contra fixtures)" "$(DESC 'lib/mole_clean.py e lib/novo_zz.py abrem um sqlite; tests/test_mole_clean.py')" 0 '"verdict": "node", "basis": "text".*mole-so-em-prosa:banco-de-dados", "mole-arquivo-novo:1"'
expect "mole: arquivo grande demais para ler (> 1 MB) + palavra -> a palavra vale, com a nota" "$(DESC 'lib/mole_big.py abre um sqlite; tests/test_mole_big.py')" 10 'moles:banco-de-dados.*"mole-ilegivel:arquivo-grande"'
expect "mole: arquivo grande demais SEM palavra -> node, com a nota de que não foi lido" "$(DESC 'lib/mole_big.py e tests/test_mole_big.py')" 0 '"verdict": "node".*"mole-ilegivel:arquivo-grande"'
expect "mole: palavra mole SEM nenhuma prova de código+teste fica unknown (antes era mini) e a palavra vai em info" "$(DESC 'revisar o banco de dados do painel')" 11 'sem-prova-de-codigo-e-teste.*"palavra-mole:banco-de-dados"'
# código que só as IRMÃS tocaram é palpite de onde a bead mexe: a evidência nele INFORMA, não bloqueia; o que a bead NOMEIA bloqueia
expect "mole: evidência em código derivado só das irmãs (palpite) informa e não barra" "$(DESCI wa-molp1.2 'corrigir o caso de borda')" 0 'prova-caminho-derivado.*mole-evidencia-irma:banco-de-dados=lib/mole_sibdb\.py\[shared/data/y\.db\]'
expect "mole: palpite das irmãs que NÃO dá para ler (> 1 MB) só vira NOTA: um palpite que informa não vira a palavra que barra ao falhar" "$(DESCI wa-molp2.2 'corrigir o caso de borda que abre um sqlite')" 0 'prova-caminho-derivado.*mole-so-em-prosa:banco-de-dados", "mole-irma-ilegivel:arquivo-grande"'
expect_not "mole: ...e esse palpite não vira \`moles:\`" "$(DESCI wa-molp1.2 'corrigir o caso de borda')" 0 'moles:'
expect "mole: palpite das irmãs com caminho absoluto: a nota em info é cortada em 48 (ga-t00j8kf)" "$(DESCI wa-molp3.2 'corrigir o caso de borda')" 0 'mole-evidencia-irma:banco-de-dados=lib/mole_sibabs\.py\[/Users/athos/gt/whatsapp_automation/shared/data/\]'
expect "mole: evidência em código que a bead NOMEIA (mole_db) bloqueia" "$(DESC 'ajustar mole_db quando vem vazio')" 10 'moles:banco-de-dados.*mole-evidencia:banco-de-dados=lib/mole_db\.py'
# as travas de exposição não mudam: freio de envio vale também para a prova pelo teste IMPORTADOR
expect "freio: envio de WhatsApp ainda manda ao mini na prova pelo teste importador" "$(DESC 'ajustar lib/impt_target.py e o envio por whatsapp')" 10 'freio-derivado:envio-acao'
expect "freio 5.12: whatsapp no RÓTULO NÃO freia a prova pelo teste importador" "$(DESC 'ajustar lib/impt_target.py e o daemon com.whatsapp.painel')" 0 '"verdict": "node", "basis": "derivado"'
expect "pii: telefone no texto segue duro mesmo com a âncora derivada" "$(DESC 'Medido em queue.db (31) 98876-5432; ajustar anchor_mod quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*dado-no-texto'
# ---- banco COM SCHEMA NO NÓ (ga-kzwlkhh, regra 4): o recibo do wa-schema-dbs.py diz quais bancos o nó TEM (cópia só-schema); só a evidência de banco que é SÓ caminho fixado/nome solto de um deles deixa de ser mole. Sem recibo, ou com
# recibo velho / do futuro / ilegível / sem placement ok, tudo segue como era (moles:banco-de-dados); recibo ausente não deixa nota, as outras causas deixam.
NOW=$(date +%s)
rcpt() { local f=$1 ts=$2 pl=$3 sep= d; shift 3; { printf '{"v":1,"delivered_at":%s,"placement":"%s","dbs":{' "$ts" "$pl"; for d in "$@"; do printf '%s"%s":"%064d"' "$sep" "$d" 0; sep=,; done; printf '}}\n'; } > "$f"; }   # rcpt <arquivo> <delivered_at> <placement> <db>...
rcpt "$T/rcpt-ok.json" "$NOW" ok shared/data/queue.db shared/data/x.db; rcpt "$T/rcpt-velho.json" $((NOW - 11 * 86400)) ok shared/data/queue.db; rcpt "$T/rcpt-futuro.json" $((NOW + 86400)) ok shared/data/queue.db
rcpt "$T/rcpt-semcol.json" "$NOW" absent shared/data/queue.db; rcpt "$T/rcpt-2h.json" $((NOW - 7200)) ok shared/data/queue.db; rcpt "$T/rcpt-sete.json" "$NOW" ok shared/data/m1.db shared/data/m2.db shared/data/m3.db shared/data/m4.db shared/data/m5.db shared/data/m6.db shared/data/m7.db
printf '{"v":1,"delivered_at":%s,"placement":"ok","dbs":{"../etc/x.db":"0"}}\n' "$NOW" > "$T/rcpt-chave.json"; printf 'nao e json' > "$T/rcpt-lixo.json"; printf '[1,2]' > "$T/rcpt-lista.json"; printf '{"v":1,"delivered_at":%s,"placement":"ok","dbs":{}}\n' "$NOW" > "$T/rcpt-vazio.json"
SA='"verdict": "node", "basis": "derivado".*mole-banco-com-schema:shared/data/queue\.db'   # relaxou: node derivado + o banco nomeado em info
SM='"verdict": "mini".*moles:banco-de-dados'                                                  # não relaxou: segue mole
SEMNOTA_SCH='"mole-evidencia:banco-de-dados=lib/sch_ok\.py\[shared/data/queue\.db\]"\]\}$'         # recibo AUSENTE: nenhuma nota depois da evidência
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-ok.json"
expect "schema: caminho fixado (shared/data/queue.db) de banco do recibo deixa de ser mole: node, com o banco nomeado em info" "$(DESC 'ajustar lib/sch_ok.py')" 0 "$SA"
expect "schema: nome solto (\"queue.db\") de banco do recibo também" "$(DESC 'ajustar lib/sch_bare.py')" 0 "$SA"
expect "schema: a palavra de banco na prosa + evidência coberta: node e a palavra NÃO vira só-em-prosa" "$(DESC 'ajustar lib/sch_ok.py que abre um sqlite')" 0 '\[shared/data/queue\.db\]", "mole-banco-com-schema:shared/data/queue\.db"\]\}$'
expect "schema: um banco do recibo + um SEM cópia (outro.db) -> segue mole" "$(DESC 'ajustar lib/sch_two.py')" 10 "$SM"
expect "schema: os dois bancos na MESMA string (ATTACH) -> segue mole" "$(DESC 'ajustar lib/sch_att.py')" 10 "$SM"
expect "schema: md:analytics junto com banco do recibo -> segue mole (MotherDuck é duro)" "$(DESC 'ajustar lib/sch_md.py')" 10 "$SM"
expect "schema: DuckDB (.duckdb) -> segue mole" "$(DESC 'ajustar lib/sch_duck.py')" 10 "$SM"
expect "schema: caminho absoluto /Users/…/shared/data/queue.db de banco do recibo -> node (ga-t00j8kf; o teste que abre o caminho fica vermelho no nó, custo de tempo e não de dado)" "$(DESC 'ajustar lib/sch_abs.py')" 0 "$SA"
expect "schema: ...o absoluto tem 56 caracteres (a evidência é guardada inteira; só a nota em info é cortada em 48)" "$(DESC 'ajustar lib/sch_abs.py')" 0 '\[/Users/athos/gt/whatsapp_automation/shared/data/\]", "mole-banco-com-schema:shared/data/queue\.db"\]\}$'
expect "schema: ~/…/shared/data/queue.db de banco do recibo -> node" "$(DESC 'ajustar lib/sch_tilde.py')" 0 "$SA"
expect "schema: absoluto de banco que NÃO está no recibo (outro.db) -> segue mole" "$(DESC 'ajustar lib/sch_abs_out.py')" 10 "$SM"
expect "schema: absoluto com pasta colada (xshared/data/queue.db) -> segue mole (a fronteira é a barra)" "$(DESC 'ajustar lib/sch_abs_dir.py')" 10 "$SM"
expect "schema: absoluto em pasta que não é shared/data (…/data/queue.db) -> segue mole, não vira o banco do recibo" "$(DESC 'ajustar lib/sch_abs_data.py')" 10 "$SM"
expect "schema: absoluto do recibo + relativo que não é (outro.db) na mesma prova -> segue mole" "$(DESC 'ajustar lib/sch_abs_two.py')" 10 "$SM"
expect "schema: absoluto + relativo, os dois do recibo -> node, com os dois nomeados" "$(DESC 'ajustar lib/sch_abs_mix.py')" 0 'mole-banco-com-schema:shared/data/queue\.db", "mole-banco-com-schema:shared/data/x\.db"'
expect "schema: shell com absoluto (sqlite3 /Users/…/shared/data/queue.db) de banco do recibo -> node" "$(DESC 'ajustar lib/sch_abs_sh.sh')" 0 "$SA"
expect "schema: Python que não parseia com absoluto de banco do recibo -> node (o ramo de texto também relaxa)" "$(DESC 'ajustar lib/sch_abs_txt.py')" 0 "$SA"
expect "schema: absoluto de EXATOS 300 caracteres que acaba no banco do recibo -> node (o teto da evidência é 300, inclusive)" "$(DESC 'ajustar lib/sch_abs_300.py')" 0 "$SA"
expect "schema: absoluto > 300 cujo corte cai no fim de queue.db (…/queue.db/mais/y.db) -> segue mole, o pedaço cortado não vira o banco do recibo" "$(DESC 'ajustar lib/sch_abs_long.py')" 10 "$SM"
expect "schema: pasta que não é shared/data (data/queue.db) -> segue mole, não vira o nome solto" "$(DESC 'ajustar lib/sch_dir.py')" 10 "$SM"
expect "schema: nome montado em f-string (shared/data/{n}.db) -> segue mole" "$(DESC 'ajustar lib/sch_fstr.py')" 10 "$SM"
expect "schema: Python que não parseia com 2 bancos (1 do recibo, 1 não) -> o texto vê os DOIS: segue mole" "$(DESC 'ajustar lib/sch_txt2.py')" 10 "$SM"
expect "schema: Python que não parseia com 1 banco do recibo -> node (o ramo de texto também relaxa)" "$(DESC 'ajustar lib/sch_txt1.py')" 0 "$SA"
expect "schema: shell (sqlite3 shared/data/queue.db) de banco do recibo -> node" "$(DESC 'ajustar lib/sch_sh.sh')" 0 "$SA"
expect "schema: banco fixado só no TESTE (x.db do recibo) -> node" "$(DESC 'ajustar lib/sch_tpin.py')" 0 '"verdict": "node".*mole-banco-com-schema:shared/data/x\.db'
expect "schema: banco do recibo + cofre no mesmo arquivo -> mini só por credencial (o banco não entra nos motivos)" "$(DESC 'ajustar lib/sch_cred.py')" 10 '"reasons": \["moles:credencial"\]'
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-sete.json"
expect "schema: 7 bancos do recibo -> 6 nomeados em info e o resto contado" "$(DESC 'ajustar lib/sch_many.py')" 0 'mole-banco-com-schema:shared/data/m6\.db", "mole-banco-com-schema-mais:1"'
expect_not "schema: ...e o 7º não é nomeado" "$(DESC 'ajustar lib/sch_many.py')" 0 'schema:shared/data/m7\.db'
export WA_NODE_SCHEMA_RECEIPT=/nonexistent/recibo.json
expect "schema: recibo AUSENTE (nunca houve entrega) -> segue mole e SEM nota (o estado de hoje)" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*$SEMNOTA_SCH"
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-velho.json"; expect "schema: recibo VELHO (11 dias) -> segue mole, com a nota" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-velho"
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-futuro.json"; expect "schema: recibo datado do FUTURO (relógio torto) -> segue mole, com a nota ilegível" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-ilegivel"
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-semcol.json"; expect "schema: recibo sem placement ok (o wt-add do nó ainda não põe o arquivo) -> segue mole, com a nota" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-sem-colocacao"
for r in chave lixo lista vazio; do export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-$r.json"; expect "schema: recibo ilegível ou de forma estranha ($r) -> segue mole, com a nota" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-ilegivel"; done
export WA_NODE_SCHEMA_RECEIPT="$T"; expect "schema: o recibo é uma PASTA (IsADirectoryError) -> segue mole, com a nota" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-ilegivel"
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-2h.json" WA_NODE_SCHEMA_MAX_AGE_H=1; expect "schema: WA_NODE_SCHEMA_MAX_AGE_H=1 e recibo de 2 h -> velho" "$(DESC 'ajustar lib/sch_ok.py')" 10 "$SM.*schema-recibo-velho"
export WA_NODE_SCHEMA_RECEIPT="$T/rcpt-ok.json" WA_NODE_SCHEMA_MAX_AGE_H=abc; expect "schema: WA_NODE_SCHEMA_MAX_AGE_H ilegível -> vale o padrão de 48 h e o recibo fresco relaxa" "$(DESC 'ajustar lib/sch_ok.py')" 0 "$SA"
unset WA_NODE_SCHEMA_MAX_AGE_H; export WA_NODE_SCHEMA_RECEIPT="$T/receipt-ausente.json"
# ---- teste IMPORTADOR (regra 6b, ga-qkc02kk): código citado SEM teste de nome ganha os testes de tests/ que o IMPORTAM (import estático que resolve para o mesmo arquivo)
expect "importador: o teste de nome sem relação que IMPORTA o módulo é a prova (basis derivado, par nomeado como teste-importador)" "$(DESC 'ajustar lib/impt_target.py')" 0 "$ME, \"reasons\": \[\"prova-teste-derivado:1-teste\(s\)\+1-codigo\(s\)\"\].*\"teste-importador:lib/impt_target\.py=tests/test_other_area\.py\""
expect "importador: teste que só CITA o nome numa string/comentário (sem import) não prova nada" "$(DESC 'ajustar lib/impt_ghost.py')" 11 'sem-prova-de-codigo-e-teste'
expect "importador: require relativo em teste .cjs também prova" "$(DESC 'ajustar lib/impt_jsx.js')" 0 "$ME.*\"teste-importador:lib/impt_jsx\.js=tests/area_js\.cjs\""
expect "importador: candidato que não parseia é PULADO e contado (a regra só afirma o que provou)" "$(DESC 'ajustar lib/impt_unparse.py')" 11 'sem-prova-de-codigo-e-teste.*"teste-importador-nao-parseou:1"'
expect "importador: pela regra 7 (módulo NOMEADO, sem caminho) o par também sai como teste-importador" "$(DESC 'ajustar impt_target quando vem vazio')" 0 "$ME.*\"teste-importador:lib/impt_target\.py=tests/test_other_area\.py\""
expect "importador: require em COMENTÁRIO de JS (// e /* */) não é import -> unknown (a regra só afirma o que provou)" "$(DESC 'ajustar lib/impt_jscm.js')" 11 'sem-prova-de-codigo-e-teste'
expect "importador: 61 testes que importam o módulo -> o 61º nem é lido, e a nota AVISA (antes ficava invisível)" "$(DESC 'ajustar lib/impt_many.py')" 0 "$ME.*\"teste-importador-truncado:1\""
printf '# so comentario\ntests/test_impt_mac*.py\n' > "$T/macs-impt.txt"
export WA_NODE_MAC_ONLY="$T/macs-impt.txt"; expect "importador: o único teste que importa é só-no-Mac -> sem prova (o nó não o tem): unknown" "$(DESC 'ajustar lib/impt_macmod.py')" 11 'sem-prova-de-codigo-e-teste'; unset WA_NODE_MAC_ONLY
# falha injetada em cada leitura do importador (só o `git grep` sai 2 / só ele demora / só ele sai 0 sem imprimir / só o `git show` do candidato sai 2): unknown COM a nota, nunca "ninguém importa"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && exit 2; done\nexec git "$@"\n' > "$T/git-grep-imp-quebra"; chmod +x "$T/git-grep-imp-quebra"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && sleep 6; done\nexec git "$@"\n' > "$T/git-grep-imp-lento"; chmod +x "$T/git-grep-imp-lento"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && exit 0; done\nexec git "$@"\n' > "$T/git-grep-imp-mudo"; chmod +x "$T/git-grep-imp-mudo"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = show ] && exit 2; done\nexec git "$@"\n' > "$T/git-show-imp-quebra"; chmod +x "$T/git-show-imp-quebra"
IMPD="$(DESC 'ajustar lib/impt_target.py')"
export WA_NODE_GIT="$T/git-grep-imp-quebra"; expect "importador: git grep que falha (rc 2) -> unknown COM a nota (\"não consegui\" != \"ninguém importa\")" "$IMPD" 11 'sem-prova-de-codigo-e-teste.*"teste-derivado-ilegivel:repo-grep-rc-2"'
export WA_NODE_GIT="$T/git-grep-imp-lento" WA_NODE_REPO_TIMEOUT=1; expect "importador: git grep que não responde no prazo -> unknown COM a nota" "$IMPD" 11 'sem-prova-de-codigo-e-teste.*"teste-derivado-ilegivel:repo-grep-sem-resposta"'; unset WA_NODE_REPO_TIMEOUT
export WA_NODE_GIT="$T/git-grep-imp-mudo"; expect "importador: git grep que sai 0 SEM imprimir nada (o que o git nunca faz) -> unknown COM a nota, não 'nenhum importa'" "$IMPD" 11 'sem-prova-de-codigo-e-teste.*"teste-derivado-ilegivel:repo-grep-ilegivel"'
export WA_NODE_GIT="$T/git-show-imp-quebra"; expect "importador: git show do candidato que falha -> unknown COM a nota" "$IMPD" 11 'sem-prova-de-codigo-e-teste.*"teste-derivado-ilegivel:teste-git-rc-2"'; unset WA_NODE_GIT
# ---- âncora do dado (regra 3, ga-qkc02kk): a bead cita SÓ dado/log que o nó não recebe e NOMEIA o módulo -> o código derivado (pelos mesmos filtros) ancora o dado como evidência
expect "âncora: dado citado + módulo nomeado e limpo -> node; o dado vira evidência e a prova ainda é exigida" "$(DESC 'Medido em queue.db; ajustar anchor_mod quando vem vazio')" 0 "$ME.*\"evidencia-ancorada-em-derivado:1\".*\"evidencia-de-dado:queue\.db\""
expect_not "âncora: só dado e NADA derivável segue duro (sem âncora inventada)" "$(DESC 'Medido em queue.db: 3 linhas sem dono')" 10 'evidencia-ancorada'
expect "âncora: só dado e nada derivável -> mini pelo caminho" "$(DESC 'Medido em queue.db: 3 linhas sem dono')" 10 'caminho-fora-do-filtro:queue\.db'
expect "âncora: módulo nomeado que o nó NÃO recebe (shared/) não ancora: o dado segue duro" "$(DESC 'Medido em queue.db; ajustar anchor_out quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*ancora-derivada-fora-do-no'
expect "âncora: módulo ancorado com evidência no código -> as moles barram" "$(DESC 'Medido em queue.db; ajustar anchor_db quando vem vazio')" 10 'moles:banco-de-dados.*evidencia-ancorada-em-derivado:1'
expect_not "âncora: se algo segurado NÃO é evidência (plist de LaunchAgents), nem se tenta ancorar" "$(DESC 'Medido em queue.db e ~/Library/LaunchAgents/x.plist; ajustar anchor_mod quando vem vazio')" 10 'evidencia-ancorada'
expect "âncora: ...e o dado segue duro junto com o plist" "$(DESC 'Medido em queue.db e ~/Library/LaunchAgents/x.plist; ajustar anchor_mod quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*caminho-fora-do-formato'
export WA_NODE_REPO="$T/wa-repo-ausente"
expect "âncora: repo ilegível -> o dado segue duro e a nota diz que a âncora não foi lida" "$(DESC 'Medido em queue.db; ajustar anchor_mod quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*"ancora-derivada-ilegivel:repo-git-rc-128"'
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
  export WA_NODE_SCHEMA_RECEIPT="$T/receipt-ausente.json"   # idem o recibo do banco com schema (um envspec que o trocou o desarmou: o seguinte leria o .gc/ de verdade)
}
mutant_pre() { MUTANT_PRE="$1"; shift; mutant "$@"; MUTANT_PRE=""; }   # mutant_pre '<comando>' <args do mutant>: o comando roda antes de CADA execução (original e mutante)
mutant sem-node-mini     '"node:mini" in labels'                       'False'                                  "$(labels "$GOOD" '["node:mini"]')" 10 'etiqueta-node:mini'
mutant sem-exec-manual     'if "exec:manual" in labels:'                  'if False:'                              "$(labels "$GOOD" '["exec:manual"]')" 10 'etiqueta-exec:manual'
mutant sem-epic          'b.get("issue_type") == "epic"'               'False'                                  "$(field "$GOOD" issue_type '"epic"')" 10 '"epic"'
mutant sem-pii           'if has_pii(json.dumps'                       'if False and has_pii(json.dumps'        "$(DESC 'lib/x.py tests/test_x.py (31) 98876-5432')" 10 'dado-no-texto'
mutant pii-sem-cauda     'len(set(d[-8:])) > 3'                        'len(set(d[-8:])) >= 0'                  "$(DESC 'lib/x.py tests/test_x.py +55 31 99999-9999')" 0 '"verdict": "node"'
mutant filtro-ignorado   'if p not in sent and p not in via_mirror:'   'if False:'                              "$(DESC 'o teste tests/test_x.py mede queue.db')" 10 'caminho-fora-do-filtro'
mutant mac-ignorado      'hard.append("so-no-mac:" + p)' 'pass'                    "$(DESC 'lib/x.py e tests/test_launchd_plist.py')" 10 'so-no-mac' "WA_NODE_MAC_ONLY=$T/macs.txt"
# o canário tem DUAS metades (o de código TEM de sair, os de segredo NÃO): um mutante por metade e um para as duas; cada um com o rsync que só ELE separa do original
mutant sem-canario       'if any(c not in sent for c in ok_canary) or any(c in sent for c in no_canary):' 'if False:'          "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-codigo 'if any(c not in sent for c in ok_canary) or any(' 'if False or any('                          "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-mudo"
mutant sem-canario-segredo 'or any(c in sent for c in no_canary):'    'or False:'                              "$GOOD" 11 'canario-errado' "WA_NODE_RSYNC=$T/rs-tudo"
mutant rc-ignorado       'if r.returncode != 0:'                       'if False:'                              "$GOOD" 11 'rsync-rc-23' "WA_NODE_RSYNC=$T/rs-parcial"
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
mutant sem-maiuscula     ', re.IGNORECASE)'                            ')'                                      "$(DESC 'tests/test_x.py e DATA/Leads.CSV')" 10 'caminho-fora-do-filtro:DATA/Leads\.CSV'   # 1ª ocorrência = PATH_RE (HOME_RE vem depois)
mutant sem-sqlite3       '|db|sqlite3?|xlsx|'                          '|db|sqlite|xlsx|'                       "$(DESC 'tests/test_x.py e data/x.sqlite3')" 10 'caminho-fora-do-filtro:data/x\.sqlite3'
mutant sem-home          'for m in HOME_RE.finditer(text):'            'for m in []:'                              "$(DESC 'lib/x.py tests/test_x.py e ~/segredos/chave.json')" 10 'caminho-fora-do-formato'
mutant mac-vazio-vale    'if not globs:'                               'if False:'                              "$GOOD" 11 'mac-only-vazio' "WA_NODE_MAC_ONLY=$T/macs-vazio.txt"
# espelho git: cada mutante troca UMA linha da regra nova e o caso designado reprova; o ambiente do caso (stub do espelho) vem em "VAR=valor"
mutant espelho-sem-negacoes 'open_sent = sent_by_filter(cands, only_denies=True)' 'open_sent = set(cands)' "$(DESC "${DOCS}shared/notas.md")" 10 'caminho-fora-do-filtro:shared/notas\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-sem-varredura 'denied = mirror_denied(mirror_rules(), ok)' 'denied = set()' "$(DESC "tests/test_x.py conforme docs/sinalizado.md")" 10 'caminho-fora-do-filtro:docs/sinalizado\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-vira-teste 'elif p in via_mirror:' 'elif False:' "$(DESC 'ajustar lib/x.py conforme docs/tests/plan.md')" 11 'sem-prova-de-codigo-e-teste.*via-espelho:docs/tests/plan\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant espelho-ext-solta 'MIRROR_TEXT_EXT = ("md",)' 'MIRROR_TEXT_EXT = ("md", "json", "txt")' "$(DESC "tests/test_x.py conforme docs/auto_response/ab_results/x.json")" 10 'caminho-fora-do-filtro:docs/auto_response/ab_results/x\.json' "WA_NODE_MIRROR=$T/mirror-ok"
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
mutant derivado-sem-freio       'if blocked:'                          'if False:'                                  "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 'freio-derivado:envio-acao' "$DV"
mutant derivado-freio-com-lead  'DERIVED_BLOCK_INFO = ("envio-acao",)' 'DERIVED_BLOCK_INFO = ("dado-de-lead", "envio-acao")' "$(DESC 'Corrigir lib/foo_parser.py; o lead some da lista')" 0 '"basis": "derivado"' "$DV"
mutant derivado-freio-sem-envio 'DERIVED_BLOCK_INFO = ("envio-acao",)' 'DERIVED_BLOCK_INFO = ()'                  "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 'freio-derivado:envio-acao' "$DV"
# ga-2hd02v.5.12: o freio ESTREITO (BRAKE_SEND_RE). Cada mutante tem um caso designado que só a mutação dele faz reprovar; o trecho original leva o contexto que o torna único (a regex larga do INFO tem palavras parecidas)
FB_WA="$(DESC 'Corrigir lib/foo_parser.py: os daemons do WhatsApp somam um nucleo de CPU')"
FB_ROTA="$(DESC 'Corrigir lib/foo_parser.py e a rota /api/curated/enviar-register da fila_envio')"
FB_BRAKE='freio-derivado:envio-acao'
mutant freio-volta-a-tag-larga   'DERIVED_BLOCK_INFO = ("envio-acao",)' 'DERIVED_BLOCK_INFO = ("envio-whatsapp",)' "$FB_WA" 0 "$FB_NODE" "$DV"
mutant freio-com-whatsapp        '(?:envios?|enviar|disparos?|evolution|baileys)(?!' '(?:whatsapp|envios?|enviar|disparos?|evolution|baileys)(?!' "$FB_WA" 0 "$FB_NODE" "$DV"
mutant freio-com-chip            '(?:envios?|enviar|disparos?|evolution|baileys)(?!' '(?:chips?|envios?|enviar|disparos?|evolution|baileys)(?!' "$(DESC 'Corrigir lib/foo_parser.py: o chip Business descartado e o ban-correlation-dashboard')" 0 "$FB_NODE" "$DV"
mutant freio-sem-tag-estreita    'info.append("envio-acao")' 'pass' "$(DESC 'Corrigir lib/foo_parser.py antes de enviar a mensagem')" 10 "$FB_BRAKE" "$DV"
mutant freio-sem-disparo         'enviar|disparos?|evolution|baileys)(?!' 'enviar|evolution|baileys)(?!' "$(DESC 'Corrigir lib/foo_parser.py no disparo diario')" 10 "$FB_BRAKE" "$DV"
mutant freio-sem-evolution       'disparos?|evolution|baileys)(?!' 'disparos?|baileys)(?!' "$(DESC 'Corrigir lib/foo_parser.py na chamada da API evolution')" 10 "$FB_BRAKE" "$DV"
mutant freio-sem-baileys         'disparos?|evolution|baileys)(?!' 'disparos?|evolution)(?!' "$(DESC 'Corrigir lib/foo_parser.py na fila do baileys')" 10 "$FB_BRAKE" "$DV"
mutant freio-hifen-exclui        '(?<![\w/.])' '(?<![\w\-/.])' "$(DESC 'Corrigir lib/foo_parser.py: o responder pode auto-enviar a mensagem')" 10 "$FB_BRAKE" "$DV"
mutant freio-sem-barra           '(?<![\w/.])' '(?<![\w.])' "$FB_ROTA" 0 "$FB_NODE" "$DV"
mutant freio-sem-underscore      '(?<![\w/.])' '(?<![/.])' "$FB_ROTA" 0 "$FB_NODE" "$DV"
mutant freio-sem-ponto-antes     '(?<![\w/.])' '(?<![\w/])' "$(DESC 'Corrigir lib/foo_parser.py no rotulo com.envio')" 0 "$FB_NODE" "$DV"
mutant freio-sem-ponto-depois    'baileys)(?![\w/]|\.\w)' 'baileys)(?![\w/])' "$(DESC 'Corrigir lib/foo_parser.py e o servico envio.worker')" 0 "$FB_NODE" "$DV"
mutant freio-tag-larga-some      '("envio-whatsapp", r"\b(whatsapp|' '("envio-wa-x", r"\b(whatsapp|' "$(DESC 'Corrigir lib/foo_parser.py; o daemon com.whatsapp.db-sync reinicia no deploy')" 0 "$FB_NODE.*\"envio-whatsapp\"" "$DV"
# ga-v8p1tx.1.3: a liberação do freio por tipo. Cada mutante tem o seu caso designado (os do bloco «liberado 1.3» lá em cima); FB_NODE e FB_BRAKE são os do bloco do 5.12. O oráculo usa $DV (o mesmo ambiente do $C9, que só é definido mais abaixo)
LIB_BUG="$(TYPED "$FREE_TXT" bug)"; LIB_TASK="$(TYPED "$FREE_TXT" task)"; LIB_CAM="$(TYPED 'revisar ficha_donos antes de enviar a mensagem' bug)"; LIB_IMP="$(TYPED 'Corrigir o envio da mensagem; teste em tests/test_imp_a.py' bug)"
RET_ANY='    return any("envio-liberado:" + t in info for t in BRAKE_FREE_TYPES)'
mutant liberado-nunca             "$RET_ANY" '    return False' "$LIB_BUG" 0 "$FB_NODE" "$DV"
mutant liberado-nunca-caminho     "$RET_ANY" '    return False' "$LIB_CAM" 0 "$FB_NODE" "$DV"
mutant liberado-nunca-importa     "$RET_ANY" '    return False' "$LIB_IMP" 0 "$FB_NODE" "$DV"
mutant liberado-sempre            "$RET_ANY" '    return True'  "$LIB_TASK" 10 "$FB_BRAKE" "$DV"
mutant liberado-sem-bug           'BRAKE_FREE_TYPES = ("bug", "feature")' 'BRAKE_FREE_TYPES = ("feature",)' "$LIB_BUG" 0 "$FB_NODE" "$DV"
mutant liberado-sem-feature       'BRAKE_FREE_TYPES = ("bug", "feature")' 'BRAKE_FREE_TYPES = ("bug",)' "$(TYPED "$FREE_TXT" feature)" 0 "$FB_NODE" "$DV"
mutant liberado-com-task          'BRAKE_FREE_TYPES = ("bug", "feature")' 'BRAKE_FREE_TYPES = ("bug", "feature", "task")' "$LIB_TASK" 10 "$FB_BRAKE" "$DV"
mutant liberado-com-chore         'BRAKE_FREE_TYPES = ("bug", "feature")' 'BRAKE_FREE_TYPES = ("bug", "feature", "chore")' "$(TYPED "$FREE_TXT" chore)" 10 "$FB_BRAKE" "$DV"
mutant liberado-sem-marca         '            info.append("envio-liberado:" + b["issue_type"])' '            pass' "$LIB_BUG" 0 "$FB_NODE" "$DV"
mutant liberado-tipo-fixo         '            info.append("envio-liberado:" + b["issue_type"])' '            info.append("envio-liberado:bug")' "$(TYPED "$FREE_TXT" feature)" 0 "$FB_NODE"'.*"envio-acao", "envio-liberado:feature"' "$DV"
mutant liberado-marca-sem-palavra 'if BRAKE_SEND_RE.search(ntext):' 'if True:' "$(TYPED 'Corrigir lib/foo_parser.py quando a entrada vem vazia.' bug)" 0 '"info": \["teste-derivado:lib/foo_parser\.py=' "$DV"
mutant liberado-vaza-no-oraculo   '    blocked = [s for s in DERIVED_BLOCK_INFO if s in info]' '    blocked = [] if brake_released(info) else [s for s in DERIVED_BLOCK_INFO if s in info]' "$(DESCB 'Corrigir o envio da mensagem: tests/test_orc_a.py reprova em main')" 10 "$FB_BRAKE" "$DV"
mutant derivado-basis-text      'basis = "derivado" if any(w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:", "prova-codigo-derivado-do-teste:", "prova-oraculo-teste-vermelho:")) for w in why) else "text"' 'basis = "text"' "$D_FOO" 0 '"basis": "derivado"' "$DV"
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
# código derivado do teste (ga-2hd02v.3.21, regra 8): um mutante por linha da regra; repo e espelho de mentira por envspec ($DV)
C8="$DV"
T8M() { DESC "Corrigir o caso de borda; teste em $1"; }
C8_RX='"verdict": "node", "basis": "derivado", "reasons": \["prova-codigo-derivado-do-teste:'
mutant codigo-sem-freio          'return judged_derived(found, "prova-codigo-derivado-do-teste", paths, tests, info, extra)' 'return "node", ["prova-codigo-derivado-do-teste:1-teste(s)+1-codigo(s)"], paths, tests, info + extra' "$(DESC 'Corrigir o envio da mensagem; teste em tests/test_imp_a.py')" 10 'freio-derivado:envio-acao' "$C8"
mutant codigo-sem-filtro         'hard.append("codigo-do-teste-fora-do-filtro:" + p)' 'pass'                  "$(T8M tests/test_imp_fora.py)" 10 'codigo-do-teste-fora-do-filtro:shared/fora_mod' "$C8"
mutant codigo-sem-mac-only       'hard.append("codigo-do-teste-so-no-mac:" + p)' 'pass'                      "$(T8M tests/test_imp_mac.py)" 10 'codigo-do-teste-so-no-mac:lib/mac_code_mod' "$C8 WA_NODE_MAC_ONLY=$T/macs-derivado7.txt"
mutant codigo-sem-teto           'if len(dpaths) > MAX_DERIVED_CODE:' 'if False:'                           "$(T8M tests/test_imp_onze.py)" 11 'codigo-do-teste-demais:11' "$C8"
mutant codigo-sem-teto-pares     'extra += pairs[:6] + (["codigo-do-teste-mais:%d"' 'extra += pairs + (["codigo-do-teste-mais:%d"' "$(T8M tests/test_imp_sete.py)" 0 'lib/limcap_06\.py", "codigo-do-teste-mais:1"\]\}$' "$C8"
mutant codigo-sem-par-em-info    'extra += pairs[:6] + (["codigo-do-teste-mais:%d"' 'extra += [] + (["codigo-do-teste-mais:%d"' "$(T8M tests/test_imp_a.py)" 0 'codigo-do-teste:tests/test_imp_a\.py=lib/imp_alpha\.py' "$C8"
mutant codigo-basis-text         '"prova-codigo-derivado-do-teste:", "prova-oraculo-teste-vermelho:"))' '"prova-oraculo-teste-vermelho:"))' "$(T8M tests/test_imp_a.py)" 0 '"basis": "derivado"' "$C8"
mutant codigo-regra7-primeiro    'if res is None and tests and not r7_failed:' 'if tests and not r7_failed:'                             "$(DESC 'Corrigir ficha_donos; teste em tests/test_imp_a.py')" 0 '"reasons": \["prova-caminho-derivado:' "$C8"
mutant codigo-falha-vira-vazio   'extra.append("codigo-do-teste-ilegivel:" + str(e))' 'pass'                  "$(T8M tests/test_imp_a.py)" 11 'codigo-do-teste-ilegivel:teste-git-rc-2' "$C8 WA_NODE_GIT=$T/git-show-quebra"
mutant codigo-parse-vira-vazio   'raise Unreadable("teste-nao-parseia")' 'return []'                         "$(T8M tests/test_imp_quebrado.py)" 11 'codigo-do-teste-ilegivel:teste-nao-parseia' "$C8"
mutant codigo-show-rc-ignorado   'raise Unreadable("%s-git-rc-%d" % (what, r.returncode))' 'pass'                  "$(T8M tests/test_imp_a.py)" 11 'codigo-do-teste-ilegivel:teste-git-rc-2' "$C8 WA_NODE_GIT=$T/git-show-quebra"
mutant codigo-show-sem-resposta  'raise Unreadable(what + "-git-sem-resposta")' 'return ""'                     "$(T8M tests/test_imp_a.py)" 11 'codigo-do-teste-ilegivel:teste-git-sem-resposta' "$C8 WA_NODE_GIT=$T/git-show-lento WA_NODE_REPO_TIMEOUT=1"
mutant codigo-grande-vale        'if len(r.stdout) > MAX_TEST_BYTES:' 'if False:'                           "$(T8M tests/test_imp_grande.py)" 11 'codigo-do-teste-ilegivel:teste-grande' "$C8"
mutant codigo-novo-vira-erro     'if t not in present or not (ext == "py" or ext in JS_TEST_EXT):' 'if not (ext == "py" or ext in JS_TEST_EXT):' "$(T8M tests/test_imp_novo.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$C8"
mutant codigo-le-head            'REPO_REF + ":" + path'               '"HEAD:" + path'                        "$(T8M tests/test_imp_head.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$C8"
mutant codigo-sem-existir        'if c in present and derivable_code(c) and t not in found.setdefault(c, []):' 'if derivable_code(c) and t not in found.setdefault(c, []):' "$(T8M tests/test_imp_a.py)" 0 "$C8_RX" "$C8"
mutant codigo-apoio-conta        'and derivable_code(c) and t not in found.setdefault' 'and t not in found.setdefault' "$(T8M tests/test_imp_apoio.py)" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$C8"
mutant codigo-relativo-sem-nivel 'for _ in range(level - 1):'          'for _ in range(0):'                    "$(T8M tests/test_imp_rel.py)" 0 "$C8_RX" "$C8"
mutant codigo-sem-submodulo      'mods = ([parts] if parts else []) + [parts + [n] for n in names]' 'mods = ([parts] if parts else [])' "$(T8M tests/test_imp_from.py)" 0 '2-codigo\(s\)' "$C8"
mutant codigo-sem-raiz-lib       'IMPORT_ROOTS = ("", "lib", "daemons", "scripts")' 'IMPORT_ROOTS = ("", "daemons", "scripts")' "$(T8M tests/test_imp_bare.py)" 0 "$C8_RX" "$C8"
mutant codigo-sem-index-js       ' + [base + "/index." + e for e in exts]' ''                                 "$(T8M tests/test_imp_js.cjs)" 0 '2-codigo\(s\)' "$C8"
mutant codigo-sem-import-from    '\bfrom\s+|'                          ''                                      "$(T8M tests/test_imp_esm.mjs)" 0 "$C8_RX" "$C8"
mutant codigo-sem-import-em-funcao 'for n in ast.walk(tree):'          'for n in tree.body:'                   "$(T8M tests/test_imp_fn.py)" 0 "$C8_RX" "$C8"
# a regra 7 que não leu NÃO libera a regra 8 (o "falhou" não vira "a 7 não derivou nada"); o cache à parte nunca é gravado pela falha, então original e mutante enxergam o mesmo git quebrado
mutant codigo-r7-falha-libera-r8 'if res is None and tests and not r7_failed:' 'if res is None and tests:' "$(DESCI wa-par1.2 'Corrigir o caso de borda; teste em tests/test_imp_a.py')" 11 "$(NOTA7 irmas-git-rc-2)" "$C8 WA_NODE_GIT=$T/git-log-quebra WA_NODE_CACHE=$T/cache-r8q-m"
mutant codigo-r7-falha-sem-flag  'r7_failed = True'  'r7_failed = False' "$(DESCI wa-par1.2 'Corrigir o caso de borda; teste em tests/test_imp_a.py')" 11 "$(NOTA7 irmas-git-rc-2)" "$C8 WA_NODE_GIT=$T/git-log-quebra WA_NODE_CACHE=$T/cache-r8q-m"
mutant codigo-teste-nao-lido-mudo 'unread.append(t)' 'pass' "$(DESC 'Corrigir o caso de borda; testes em tests/test_imp_a.py e tests/test_imp_novo.py')" 0 'teste-nao-lido:tests/test_imp_novo\.py' "$C8"
mutant codigo-sem-teto-nao-lidos 'unread[:3]' 'unread' "$(DESC 'Corrigir o caso de borda; testes em tests/test_imp_a.py, tests/test_n1.py, tests/test_n2.py, tests/test_n3.py e tests/test_n4.py')" 0 'teste-nao-lido:tests/test_n3\.py", "teste-nao-lido-mais:1"\]\}$' "$C8"
# oráculo = teste vermelho em main (ga-2hd02v.5.13, regra 9): um mutante por linha da regra; repo e espelho de mentira por envspec ($DV); cada caso designado só reprova com a mutação dele
C9="$DV"
C9_RX='"verdict": "node", "basis": "derivado", "reasons": \["prova-oraculo-teste-vermelho:'
mutant oraculo-tipo-qualquer     'b.get("issue_type") != "bug" or '    ''                                       "$(DESCTY task 'tests/test_orc_a.py reprova em main')" 11 "$U9" "$C9"
mutant oraculo-sem-vermelho      ' or not red_in_main(ntext)'          ''                                       "$(DESCB 'Os achados fecham os buracos de falha silenciosa que a feature deixou; tests/test_orc_a.py cobre o caso')" 11 "$U9" "$C9"
mutant oraculo-sem-main          'for m in MAIN_RE.finditer(ntext):'   'for m in re.finditer(r"\w+", ntext):' "$(DESCB 'Os achados fecham os buracos de falha silenciosa que a feature deixou; tests/test_orc_a.py cobre o caso')" 11 "$U9" "$C9"
mutant oraculo-sem-frase         'SENT_SPLIT_RE = re.compile(r"\n|\. |; ")' 'SENT_SPLIT_RE = re.compile(r"\n")' "$(DESCB 'A falha silenciosa do sync. Depois do merge em main a ordem muda; tests/test_orc_a.py cobre o caso')" 11 "$U9" "$C9"
mutant oraculo-sem-negacao       'any(not NEG_PRE_RE.search(seg[max(0, r.start() - 30):r.start()]) for r in RED_RE.finditer(seg))' 'any(True for r in RED_RE.finditer(seg))' "$(DESCB 'tests/test_orc_a.py não reprova em main; o problema aparece só no tablet')" 11 "$U9" "$C9"
mutant oraculo-sem-verde         'if GREEN_RE.search(seg):'            'if False:'                              "$(DESCB 'tests/test_orc_a.py passa em main mas falha no tablet')" 11 "$U9" "$C9"
mutant oraculo-main-solto        '|\s+(?:thread|loop|process|function|funcao))'  ')'                            "$(DESCB 'tests/test_orc_a.py falha na main thread do worker')" 11 "$U9" "$C9"
mutant oraculo-main-parenteses   '(?![\w/\-(]|\.\w|'                  '(?![\w/\-]|\.\w|'                       "$(DESCB 'tests/test_orc_a.py falha em main() do worker')" 11 "$U9" "$C9"
mutant oraculo-sem-reprova       'reprov(?:a|am|ando|ou)|'             ''                                       "$(DESCB 'tests/test_orc_a.py reprova em main')" 0 '"reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]' "$C9"
mutant oraculo-sem-falha         '|falh(?:a|am|ando|ou)|'              '|'                                      "$(DESCB 'tests/test_orc_a.py falha em main')" 0 '"reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]' "$C9"
mutant oraculo-sem-vermelho-palavra '|vermelh[oa]s?|'                  '|'                                      "$(DESCB 'tests/test_orc_a.py está vermelho em main')" 0 '"reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]' "$C9"
mutant oraculo-sem-quebrado      '|quebrad[oa]s?|'                     '|'                                      "$(DESCB 'tests/test_orc_a.py ficou quebrado em main')" 0 '"reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]' "$C9"
mutant oraculo-sem-fails         '|fail(?:s|ing|ed)?)'                 ')'                                      "$(DESCB 'tests/test_orc_a.py fails in origin/main')" 0 '"reasons": \["prova-oraculo-teste-vermelho:1-teste\(s\)"\]' "$C9"
mutant oraculo-sem-teste         'if res is None and tests and not r7_failed and not r8_failed' 'if res is None and not r7_failed and not r8_failed' "$(DESCB 'O teste do modulo reprova em main')" 11 "$U9" "$C9"
mutant oraculo-sobrepoe-regra8   'if res is None and tests and not r7_failed and not r8_failed' 'if tests and not r7_failed and not r8_failed' "$(DESCB 'tests/test_imp_a.py reprova em main')" 0 '"reasons": \["prova-codigo-derivado-do-teste:' "$C9"
mutant oraculo-r7-falha-libera   'and not r7_failed and not r8_failed and not any(' 'and not r8_failed and not any(' "$(DESCBI wa-par1.2 'tests/test_orc_a.py reprova em main')" 11 "$(NOTA7 irmas-git-rc-2)" "$C9 WA_NODE_GIT=$T/git-log-quebra WA_NODE_CACHE=$T/cache-orq-m"
mutant oraculo-r8-falha-libera   'and not r8_failed and not any('      'and not any('                           "$(DESCB 'tests/test_imp_quebrado.py reprova em main')" 11 "$(NOTA8 teste-nao-parseia)" "$C9"
mutant oraculo-r8-falha-sem-flag 'r8_failed = True'                    'r8_failed = False'                      "$(DESCB 'tests/test_imp_quebrado.py reprova em main')" 11 "$(NOTA8 teste-nao-parseia)" "$C9"
mutant oraculo-demais-libera     ' and not any(x.startswith("codigo-do-teste-demais") for x in extra)' '' "$(DESCB 'tests/test_imp_onze.py reprova em main')" 11 'sem-prova-de-codigo-e-teste.*"info": \["codigo-do-teste-demais:11"\]\}$' "$C9"
mutant oraculo-ausente-vale      '    if absent:'                      '    if False:'                          "$(DESCB 'tests/test_orc_novo.py reprova em main')" 11 "$U9"'.*"oraculo-teste-fora-de-main:tests/test_orc_novo\.py"' "$C9"
mutant oraculo-ausente-so-se-todos '    if absent:'                    '    if len(absent) == len(tests):'     "$(DESCB 'tests/test_orc_a.py e tests/test_orc_novo.py reprovam em main')" 11 "$U9"'.*"oraculo-teste-fora-de-main:tests/test_orc_novo\.py"' "$C9"
mutant oraculo-ausente-mudo      'for t in absent[:3]]'                'for t in []]'                           "$(DESCB 'tests/test_orc_novo.py reprova em main')" 11 "$U9"'.*"oraculo-teste-fora-de-main:tests/test_orc_novo\.py"' "$C9"
mutant oraculo-sem-teto-ausentes '"oraculo-teste-fora-de-main:" + t for t in absent[:3]]' '"oraculo-teste-fora-de-main:" + t for t in absent]' "$(DESCB 'tests/test_orc_a.py, tests/test_n1.py, tests/test_n2.py, tests/test_n3.py e tests/test_n4.py reprovam em main')" 11 'oraculo-teste-fora-de-main:tests/test_n3\.py", "oraculo-teste-fora-de-main-mais:1"\]\}$' "$C9"
mutant oraculo-sem-freio         $'return "mini", ["freio-derivado:" + ",".join(blocked)], paths, tests, info + extra\n    return "node", ["prova-oraculo-teste-vermelho' $'pass\n    return "node", ["prova-oraculo-teste-vermelho' "$(DESCB 'Corrigir o envio da mensagem: tests/test_orc_a.py reprova em main')" 10 '"reasons": \["freio-derivado:envio-acao"\]' "$C9"
mutant oraculo-basis-text        ', "prova-oraculo-teste-vermelho:")) for w in why)' ')) for w in why)'       "$O9_9B70JK" 0 '"basis": "derivado"' "$C9"
mutant oraculo-texto-cru         'oracle_derivation(b, ntext, tests, paths, info, extra)' 'oracle_derivation(b, text, tests, paths, info, extra)' "$O9_JZAA2W" 0 "$C9_RX" "$C9"
mutant oraculo-conta-um          '"prova-oraculo-teste-vermelho:%d-teste(s)" % len(tests)' '"prova-oraculo-teste-vermelho:%d-teste(s)" % 1' "$O9_JZAA2W" 0 "$C9_RX"'2-teste\(s\)"\]' "$C9"
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
mutant solto-dado-tambem         'RESOLVE_EXT = CODE_EXT + ("html", "md")' 'RESOLVE_EXT = CODE_EXT + ("html", "md", "json")' "$(DESC "lib/x.py e $SOLTO_TESTE: ler solto_dado.json")" 0 '"paths": \["lib/x\.py", "tests/test_x\.py", "solto_dado\.json"\].*evidencia-de-dado:solto_dado\.json' "$SV"
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
mutant caminho-com-codigo-citado 'if not [c for c in code if c not in ghosts]:' 'if True:'                         "$(DESC 'ajustar lib/sem_teste_mod.py e a ficha_donos')" 11 "$SEMNOTA" "$R7"
mutant caminho-basis-text       'w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:", "prova-codigo-derivado-do-teste:", "prova-oraculo-teste-vermelho:"))' 'w.startswith("prova-teste-derivado:")' "$FD" 0 '"basis": "derivado"' "$R7"
mutant caminho-sem-freio        'if blocked:'                          'if False:'                                  "$(DESC 'revisar ficha_donos antes de enviar a mensagem')" 10 'freio-derivado:envio-acao.*caminho-derivado:nome:ficha_donos' "$R7"
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
# cópia de backup (ga-2hd02v.3.22): um mutante por linha da regra; o que reaceita a cópia (backup-aceito, backup-irma-aceita) é o que o Mayor pediu que reprove
mutant backup-aceito            'fs = [f for f in fs if not in_backup_dir(f)]' 'fs = fs'                                  "$(DESC 'revisar bak_viva_mod quando vem vazio')" 0 "$N_OK" "$R7"
mutant backup-so-copia-some     'if n in live_stems:'                  'if True:'                                           "$(DESC 'revisar so_copia_mod quando vem vazio')" 10 'caminho-derivado-fora-do-filtro:daemons\.bak-' "$R7"
mutant backup-ambiguidade-total 'if len(fs) > MAX_FILES_PER_NAME:'     'if len(by_stem.get(n, [])) > MAX_FILES_PER_NAME:'   "$(DESC 'revisar amb_copia_mod quando vem vazio')" 0 'prova-caminho-derivado:1-teste\(s\)\+2-codigo\(s\)' "$R7"
mutant backup-irma-aceita       'if in_backup_dir(f) and file_stem(f) in live_stems:' 'if False:'                           "$(DESCI wa-par6.2 'corrigir o caso de borda')" 0 'caminho-derivado:irmas=lib/irma_copia_mod' "$R7"
mutant backup-irma-sem-vivo     'if in_backup_dir(f) and file_stem(f) in live_stems:' 'if in_backup_dir(f):'                  "$(DESCI wa-par7.2 'corrigir o caso de borda')" 10 'caminho-derivado-fora-do-filtro:daemons\.bak-' "$R7"
mutant backup-sem-archive       '("bak", "backup", "backups", "archive", "archived")' '("bak", "backup", "backups")'      "$(DESC 'revisar arq_viva_mod quando vem vazio')" 0 'caminho-derivado-backup-ignorado:1' "$R7"
mutant backup-nome-do-arquivo   'for seg in f.split("/")[:-1]'         'for seg in f.split("/")'                            "$(DESC 'revisar bak_viva_mod quando vem vazio')" 0 "$N_OK" "$R7"
mutant backup-segmento-inteiro  're.split(r"[._\-0-9]+", seg.lower())'  '[seg.lower()]'                                      "$(DESC 'revisar bak_viva_mod quando vem vazio')" 0 "$N_OK" "$R7"
# nome solto fantasma (ga-2hd02v.3.22)
mutant fantasma-conta-como-codigo 'if not [c for c in code if c not in ghosts]:' 'if not code:'                              "$(DESC 'diagnostico em part_diag.py: revisar ficha_donos quando vem vazia')" 0 "$N_OK" "$R7"
mutant fantasma-sem-arvore-lida 'elif ok and not hits and'             'elif not hits and'                                  "$(DESC 'diagnostico em part_diag.py: revisar ficha_donos quando vem vazia')" 11 'caminho-solto-ilegivel:repo-git-rc-128", "teste-derivado-ilegivel:repo-git-rc-128"\]\}$' "WA_NODE_REPO=$T/wa-repo-ausente WA_NODE_MIRROR=$T/mirror-ok WA_NODE_CACHE=/dev/null/sem-cache"
mutant fantasma-ambiguo         'elif ok and not hits and'             'elif ok and len(hits) != 1 and'                     "$(DESC 'ajustar dupmod_x.py e revisar ficha_donos')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$R7"
mutant fantasma-sem-nota        'note += ["caminho-solto-fora-da-arvore:" + p for p in sorted(ghosts)]' 'pass'               "$(DESC 'diagnostico em part_diag.py da fila de busca')" 11 'caminho-solto-fora-da-arvore:part_diag' "$R7"
# cache: o estado é escrito à mão antes de cada execução (o original, ao recalcular, regrava o cache e o mutante leria o que ele gravou)
CM="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_CACHE=$T/cache-m"
mutant_pre "seedc $T/cache-m wa-parc 60 '[\"lib/ficha_donos.py\"]'" cache-ignorado '-60 <= age <= SIBLING_TTL' 'False' "$(DESCI wa-parc.1 'corrigir o caso de borda')" 0 '"cache": "hit"' "$CM"
mutant_pre "seedc $T/cache-m wa-parv $((7*3600)) '[\"lib/ficha_donos.py\"]'" cache-vencido-vale '-60 <= age <= SIBLING_TTL' '-60 <= age' "$(DESCI wa-parv.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$CM"
mutant_pre "seedc $T/cache-m wa-parw 60 '[\"lib/ficha_donos.py\"]' wa-outro" cache-outro-pai 'd["parent"] == parent and ' '' "$(DESCI wa-parw.1 'corrigir o caso de borda')" 11 "sem-prova-de-codigo-e-teste.*$SEMNOTA" "$CM"
# ---- controle negativo da evidência (ga-t05a1z9): cada linha nova do classificador tem um mutante e um caso que só o original passa
mutant ev-sem-codigo      'has_code = any(c not in ghosts for c in code)'  'has_code = True'                         "$(DESC 'o teste tests/test_foo.py mede queue.db')" 10 'caminho-fora-do-filtro:queue\.db'
mutant ev-sem-extensao    'if ext in EVIDENCE_EXT or any(s.lower() in EVIDENCE_DIRS for s in segs[:-1]):' 'if any(s.lower() in EVIDENCE_DIRS for s in segs[:-1]):' "$EVID" 0 'evidencia-de-dado:queue\.db'
mutant ev-sem-pasta       'if ext in EVIDENCE_EXT or any(s.lower() in EVIDENCE_DIRS for s in segs[:-1]):' 'if ext in EVIDENCE_EXT:'  "$(DESC "${DOCS}logs/relatorio.md")" 0 'evidencia-de-dado:logs/relatorio\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant ev-segredo         'if not ext or ext in NOT_EVIDENCE_EXT or secretish(p):' 'if not ext or ext in NOT_EVIDENCE_EXT:' "$(DESC 'scripts/foo.py lê config/senha_prod.json; tests/test_foo.py')" 10 'caminho-fora-do-filtro:config/senha_prod\.json'
mutant ev-codigo-fora     'if not ext or ext in NOT_EVIDENCE_EXT or secretish(p):' 'if not ext or secretish(p):' "$(DESC 'lib/x.py usa data/helper.py; tests/test_x.py')" 10 'caminho-fora-do-filtro:data/helper\.py'
mutant ev-segredo-prefixo 't.startswith(SECRET_PREFIX) or t in SECRET_WORD' 't in SECRET_WORD'                         "$(DESC 'scripts/foo.py lê dados/segredos/x.csv; tests/test_foo.py')" 10 'caminho-fora-do-filtro:dados/segredos/x\.csv'
mutant ev-segredo-palavra 't.startswith(SECRET_PREFIX) or t in SECRET_WORD' 't.startswith(SECRET_PREFIX)'               "$(DESC 'scripts/foo.py lê config/map_key.json; tests/test_foo.py')" 10 'caminho-fora-do-filtro:config/map_key\.json'
mutant ev-key-em-palavra  't.startswith(SECRET_PREFIX) or t in SECRET_WORD' 't.startswith(SECRET_PREFIX) or any(w in t for w in SECRET_WORD)' "$(DESC 'scripts/foo.py lê config/monkey_patch.json; tests/test_foo.py')" 0 'evidencia-de-dado:config/monkey_patch\.json'
mutant ev-mole-fica       'soft_text = soft_text.replace(tok, " ")'        'pass'                                   "$EVID" 0 '"reasons": \["prova-no-texto:1-teste\(s\)\+1-codigo"\]'
mutant ev-ordem           'key=len, reverse=True'                           'key=len, reverse=False'                 "$(DESC 'scripts/foo.py e tests/test_foo.py; lot.db medido em /Users/athos/shared/data/m/lot.db')" 0 '"verdict": "node"'
mutant ev-formato-solto   'blocked += [("caminho-fora-do-formato", o, o) for o in odd]' 'blocked += []'                  "$(DESC 'lib/x.py e /etc/zz_evil.py com tests/test_x.py')" 10 'caminho-fora-do-formato'
mutant ev-doc-retido      'kind = "doc" if p in withheld and not secretish(p) else evidence_kind(p)' 'kind = evidence_kind(p)' "$(DESC "${DOCS}docs/sinalizado.md")" 0 'evidencia-de-doc:docs/sinalizado\.md' "WA_NODE_MIRROR=$T/mirror-ok"
mutant ev-retido-na-falha 'return [], ["espelho-ilegivel:" + str(e)], []' 'return [], ["espelho-ilegivel:" + str(e)], cands' "$(DESC 'lib/x.py conforme docs/guia.md; tests/test_x.py')" 10 'caminho-fora-do-filtro:docs/guia\.md.*espelho-' "WA_NODE_MIRROR=$T/espelho-ausente"
mutant ev-info-sem-teto   'info += names[:MAX_EVIDENCE_INFO] +'            'info += names +'                        "$(DESC "scripts/foo.py tests/test_foo.py medido em ${EV10}")" 0 'evidencia-de-dado:x8\.log", "evidencia-de-dado-mais:2"'
# ---- controle negativo das moles por evidência, do teste importador e da âncora (ga-qkc02kk): cada linha nova do classificador tem um mutante e um caso que só o original passa
MD="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok"
MR="WA_NODE_REPO=$T/wa-repo-ausente WA_NODE_MIRROR=$T/espelho-ausente"
MCLEAN="$(DESC 'ajustar lib/mole_clean.py que abre um sqlite com o token e roda osascript')"
mutant mole-sem-evidencia        'hard = ["moles:" + s for s in MOLE_SLUGS if s in ev]' 'hard = []'                                          "$(DESC 'ajustar lib/mole_db.py')" 10 'moles:banco-de-dados' "$MD"
mutant mole-palavra-barra        'hard = ["moles:" + s for s in MOLE_SLUGS if s in ev]' 'hard = ["moles:" + s for s in MOLE_SLUGS if s in ev or s in prose]' "$MCLEAN" 0 'mole-so-em-prosa:banco-de-dados' "$MD"
mutant mole-falha-vira-sem-evid  'return fallback, ["mole-ilegivel:" + str(e)]'         'return [], ["mole-ilegivel:" + str(e)]'            "$(DESC 'lib/mole_clean.py abre um sqlite; tests/test_mole_clean.py')" 10 'moles:banco-de-dados.*mole-ilegivel' "$MR"
mutant mole-falha-sem-nota       'fallback, ["mole-ilegivel:" + str(e)]'                'fallback, []'                                      "$(DESC 'lib/mole_clean.py e tests/test_mole_clean.py')" 0 'mole-ilegivel:repo-git-rc-128' "$MR"
mutant mole-sem-base-vira-vazio  '    if nread == 0:'                                    '    if False:'                                     "$(DESC 'lib/novo_zz.py abre um sqlite; tests/test_novo_zz.py')" 10 'moles:banco-de-dados.*mole-sem-arquivo-lido' "$MD"
mutant mole-novo-bloqueia        'novos.append(f)'                                      'raise Unreadable("novo")'                          "$(DESC 'lib/mole_clean.py e lib/novo_zz.py abrem um sqlite; tests/test_mole_clean.py')" 0 'mole-arquivo-novo:1' "$MD"
mutant mole-docstring-conta      ' and id(n) not in docs and id(n) not in pieces:'     ' and id(n) not in pieces:'                    "$(DESC 'ajustar lib/mole_clean.py')" 0 '"verdict": "node"' "$MD"
mutant mole-sem-ast              'parts = py_exec_parts(text) if path.endswith(".py") else None' 'parts = None'                                 "$(DESC 'ajustar lib/mole_clean.py')" 0 '"verdict": "node"' "$MD"
mutant mole-teste-bare-conta     'for w in db_refs(t, is_test):'                   'for w in db_refs(t, False):'                   "$(DESC 'ajustar lib/mole_tbare.py')" 0 '"verdict": "node"' "$MD"
mutant mole-texto-teste-bare     'for w in db_refs(blob, is_test):'                'for w in db_refs(blob, False):'                "$(DESC 'ajustar lib/mole_tbare2.py')" 0 '"verdict": "node"' "$MD"
mutant mole-stdlib-secrets       '|_?secret(?:_bin|_cli)?)(?:\.|$)", re.I)'            '|_?secrets?(?:_bin|_cli)?)(?:\.|$)", re.I)'                       "$(DESC 'ajustar lib/mole_stdsec.py')" 0 '"verdict": "node"' "$MD"
mutant mole-cofre-argv-ignorado  '            if b in CRED_CLI:'                        '            if False:'                             "$(DESC 'ajustar lib/mole_cred.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-chamada        '            if CRED_CALL_RE.match(c):'               '            if False:'                             "$(DESC 'ajustar lib/mole_credfn.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-arquivo        '            elif CRED_FILE_RE.search(t):'            '            elif False:'                           "$(DESC 'ajustar lib/mole_credpem.py')" 10 'moles:credencial' "$MD"
mutant mole-host-argv-ignorado   '            if b in HOST_ARGV:'                       '            if False:'                             "$(DESC 'ajustar lib/mole_secarg.py')" 10 'moles:host-mac' "$MD"
mutant mole-chrome-ignorado      '|Application Support/Google/Chrome'                   ''                                                  "$(DESC 'ajustar lib/mole_chrome.py')" 10 'moles:host-mac' "$MD"
mutant mole-md-ignorado          '|(?<![\w])md:[\w\-]*'                              ''                                                  "$(DESC 'ajustar lib/mole_md.py e tests/test_mole_md.py')" 10 'moles:banco-de-dados' "$MD"
mutant mole-users-conta          '|~/Library|remote-debugging-port'                    '|~/Library|/Users/[A-Za-z]|remote-debugging-port' "$(DESC 'ajustar lib/mole_users.py')" 0 '"verdict": "node"' "$MD"
mutant mole-texto-com-comentario '    blob = strip_comment_lines(text)'               '    blob = text'                                   "$(DESC 'ajustar lib/mole_shclean.sh')" 0 '"verdict": "node"' "$MD"
mutant mole-irma-bloqueia        '(PROOF_SOFT if DERIVED_SRC.get(c) == "irmas" else PROOF).add(c)' 'PROOF.add(c)'                           "$(DESCI wa-molp1.2 'corrigir o caso de borda')" 0 'mole-evidencia-irma' "$MD"
mutant mole-irma-falha-barra     'softbad.append("mole-irma-ilegivel:" + str(e))'      'raise'                                             "$(DESCI wa-molp2.2 'corrigir o caso de borda que abre um sqlite')" 0 'mole-irma-ilegivel:arquivo-grande' "$MD"
mutant mole-irma-nao-le          'for f in sorted(x for x in soft_files if x not in proof'  'for f in sorted(x for x in soft_files if False and x not in proof' "$(DESCI wa-molp1.2 'corrigir o caso de borda')" 0 'mole-evidencia-irma' "$MD"
mutant mole-portao-no-label      'if v == "node" and "etiqueta-node:ok" not in why:'   'if v == "node":'                                   "$(labels "$(DESC 'ajustar lib/mole_db.py que abre um sqlite')" '["node:ok"]')" 0 '"basis": "label"' "$MD"
mutant mole-palavra-sem-prova    'elif v == "unknown" and PROSE:'                      'elif False:'                                       "$(DESC 'revisar o banco de dados do painel')" 11 'palavra-mole:banco-de-dados' "$MD"
mutant importador-sem-import     '        if code in cands:'                           '        if True:'                                      "$(DESC 'ajustar lib/impt_ghost.py')" 11 'sem-prova-de-codigo-e-teste' "$MD"
mutant importador-nome-vence     'if s and p not in cand and (p.endswith(".py")'       'if s and (p.endswith(".py")'                       "$(DESC 'Corrigir lib/foo_parser.py quando a entrada vem vazia.')" 0 'prova-teste-derivado:3-teste' "$MD"
mutant importador-sem-mac-only   '        ok = [t for t in ts if t in keep]'           '        ok = list(ts)'                                 "$(DESC 'ajustar lib/impt_macmod.py')" 11 'sem-prova-de-codigo-e-teste' "$MD WA_NODE_MAC_ONLY=$T/macs-impt.txt"
mutant importador-rotulo-regra6  '"teste-importador" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in code' '"teste-derivado" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in code' "$(DESC 'ajustar lib/impt_target.py')" 0 'teste-importador:lib/impt_target' "$MD"
mutant importador-rotulo-regra7  '"teste-importador" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in dpaths' '"teste-derivado" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in dpaths' "$(DESC 'ajustar impt_target quando vem vazio')" 0 'teste-importador:lib/impt_target' "$MD"
IMPQ="WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-grep-imp-quebra"
mutant importador-grep-rc-ignorado   $'raise Unreadable("repo-grep-rc-%d" % r.returncode)\n    pre = REPO_REF + ":"\n    hits = sorted(' $'pass\n    pre = REPO_REF + ":"\n    hits = sorted(' "$IMPD" 11 'teste-derivado-ilegivel:repo-grep-rc-2' "$IMPQ"
mutant importador-grep-sem-resposta  $'raise Unreadable("repo-grep-sem-resposta")\n    if r.returncode not in (0, 1):\n        raise Unreadable("repo-grep-rc-%d" % r.returncode)\n    pre = REPO_REF + ":"\n    hits = sorted(' $'return []\n    if r.returncode not in (0, 1):\n        raise Unreadable("repo-grep-rc-%d" % r.returncode)\n    pre = REPO_REF + ":"\n    hits = sorted(' "$IMPD" 11 'teste-derivado-ilegivel:repo-grep-sem-resposta' "WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-grep-imp-lento WA_NODE_REPO_TIMEOUT=1"
mutant importador-grep-mudo-vale     $'raise Unreadable("repo-grep-ilegivel")\n    cand_all = ' $'pass\n    cand_all = ' "$IMPD" 11 'teste-derivado-ilegivel:repo-grep-ilegivel' "WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-grep-imp-mudo"
mutant importador-show-vira-vazio    'src = repo_show(t)   # falhou/ilegível -> Unreadable sobe' 'src = ""   # falhou/ilegível -> Unreadable sobe' "$IMPD" 11 'teste-derivado-ilegivel:teste-git-rc-2' "WA_NODE_REPO=$RP WA_NODE_MIRROR=$T/mirror-ok WA_NODE_GIT=$T/git-show-imp-quebra"
# gate-fix 1 (ga-qkc02kk): o ramo `ast` tem de ser tão largo quanto o de texto no idioma do cofre/Mac
mutant mole-cofre-caminho-ignorado   '    if t.startswith(("/", "~", "$", "_/", "bin/")) or "/bin/" in t:' '    if False:'                       "$(DESC 'ajustar lib/mole_credpath.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-bin-ignorado       '"_/", "bin/")) or "/bin/" in t:'                  '"_/", "bin/")) or False:'                          "$(DESC 'ajustar lib/mole_credconst.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-json-shell         '|run)\b)|bitwarden|(?<![\w/])\.env\b|credentials?[\w\-]*\.json'  '|run)\b)|bitwarden|(?<![\w/])\.env\b' "$(DESC 'ajustar lib/mole_credjson.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-sql-ignorado       '|\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:PERSISTENT\s+|TEMPORARY\s+)?SECRET\b", re.I)   # texto de UMA string'  '", re.I)   # texto de UMA string'  "$(DESC 'ajustar lib/mole_credsql.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-shell-ignorado    '                m = CRED_SHELL_RE.search(t)'        '                m = None'                                "$(DESC 'ajustar lib/mole_credpopen.py')" 10 'moles:credencial' "$MD"
mutant mole-fstring-ignorada         '        elif isinstance(n, ast.JoinedStr):'          '        elif False:'                                  "$(DESC 'ajustar lib/mole_dbf.py')" 10 'moles:banco-de-dados' "$MD"
mutant mole-fstring-pedacos-soltos   ' and id(n) not in docs and id(n) not in pieces:'     ' and id(n) not in docs:'                           "$(DESC 'ajustar lib/mole_prose.py')" 0 '"verdict": "node"' "$MD"
mutant mole-cofre-wrapper-chamada    'secret(?:_bin|_cli)?$|^_*(?:bw'                    'secret$|^_*(?:bw'                                  "$(DESC 'ajustar lib/mole_credcall.py')" 10 'moles:credencial' "$MD"
mutant mole-cofre-wrapper-modulo     '|_?secret(?:_bin|_cli)?)(?:\.|$)", re.I)   #'     '|_?secret)(?:\.|$)", re.I)   #'                    "$(DESC 'ajustar lib/mole_credmod.py')" 10 'moles:credencial' "$MD"
mutant mole-host-chamada-ignorada    '            if HOST_CALL_RE.search(c):'              '            if False:'                                "$(DESC 'ajustar lib/mole_hostcdp.py')" 10 'moles:host-mac' "$MD"
mutant mole-host-modulo-ignorado     '            if any(HOST_CALL_RE.search(x) for x in m.split(".")):' '            if False:'                      "$(DESC 'ajustar lib/mole_hostmod.py')" 10 'moles:host-mac' "$MD"
mutant mole-host-shell-ignorado      'm = HOST_RE.search(t) or HOST_SHELL_RE.search(t)'  'm = HOST_RE.search(t)'                              "$(DESC 'ajustar lib/mole_hostshell.py')" 10 'moles:host-mac' "$MD"
mutant mole-prosa-vira-cofre         '(?:^\s*|[;|&(`]\s*)(?:\S*/)?(?:secret\s+'        '(?:\s*)(?:\S*/)?(?:secret\s+'                    "$(DESC 'ajustar lib/mole_prose.py')" 0 '"verdict": "node"' "$MD"
mutant importador-js-comentario-conta $'                cands = [c for m in JS_IMPORT_RE.finditer(strip_js_comments(src))' $'                cands = [c for m in JS_IMPORT_RE.finditer(src)' "$(DESC 'ajustar lib/impt_jscm.js')" 11 'sem-prova-de-codigo-e-teste' "$MD"
mutant importa-js-comentario-conta    $'        else:\n            cands = [c for m in JS_IMPORT_RE.finditer(strip_js_comments(src))' $'        else:\n            cands = [c for m in JS_IMPORT_RE.finditer(src)' "$(T8M tests/test_imp_jscm.cjs)" 11 'sem-prova-de-codigo-e-teste' "$C8"
mutant importador-trunca-sem-nota    'NOTES.append("teste-importador-truncado:%d" % (len(cand_all) - len(cand)))' 'pass'                    "$(DESC 'ajustar lib/impt_many.py')" 0 'teste-importador-truncado:1' "$MD"
mutant importador-pula-sem-nota  'NOTES.append("teste-importador-nao-parseou:%d" % skipped)' 'pass'                                           "$(DESC 'ajustar lib/impt_unparse.py')" 11 'teste-importador-nao-parseou:1' "$MD"
mutant ancora-sem-filtro         '    if any(p not in dsent or any(fnmatch.fnmatchcase(p, g) for g in globs) for p in dpaths):' '    if False:'      "$(DESC 'Medido em queue.db; ajustar anchor_out quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*ancora-derivada-fora-do-no' "$MD"
mutant ancora-falha-sem-nota     '        info += anotes'                              '        pass'                                          "$(DESC 'Medido em queue.db; ajustar anchor_mod quando vem vazio')" 10 'ancora-derivada-ilegivel:repo-git-rc-128' "$MR"
mutant ancora-ignora-pii         'if not has_code and blocked and not hard and all('    'if not has_code and blocked and all('              "$(DESC 'Medido em queue.db (31) 98876-5432; ajustar anchor_mod quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*dado-no-texto' "$MD"
mutant ancora-sem-exigir-evid    'for _, p, _ in blocked):'                            'for _, p, _ in []):'                               "$(DESC 'Medido em queue.db e ~/Library/LaunchAgents/x.plist; ajustar anchor_mod quando vem vazio')" 10 'caminho-fora-do-filtro:queue\.db.*caminho-fora-do-formato' "$MD"
# ---- controle negativo do banco COM SCHEMA NO NÓ (ga-kzwlkhh): cada guarda do recibo e da cobertura tem um mutante e um caso que só o original passa
SR="$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-ok.json"; SOK="$(DESC 'ajustar lib/sch_ok.py')"
mutant schema-velho-vale          'if age > SCHEMA_MAX_AGE:'                         'if False:'                                       "$SOK" 10 'schema-recibo-velho' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-velho.json"
mutant schema-futuro-vale         'if age < -300:'                                   'if False:'                                       "$SOK" 10 'schema-recibo-ilegivel' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-futuro.json"
mutant schema-sem-colocacao-vale  'if rec.get("placement") != "ok":'                'if False:'                                       "$SOK" 10 'schema-recibo-sem-colocacao' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-semcol.json"
mutant schema-chave-frouxa        ' or not all(isinstance(k, str) and SCHEMA_KEY_RE.match(k) for k in dbs)' '' "$SOK" 10 'schema-recibo-ilegivel' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-chave.json"
mutant schema-ausente-com-nota    'except FileNotFoundError:'                        'except ZeroDivisionError:'                       "$SOK" 10 "$SM.*$SEMNOTA_SCH" "$MD WA_NODE_SCHEMA_RECEIPT=/nonexistent/recibo.json"
mutant schema-prazo-fixo          'int(os.environ.get("WA_NODE_SCHEMA_MAX_AGE_H", "48"))' '48'                                         "$SOK" 10 'schema-recibo-velho' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-2h.json WA_NODE_SCHEMA_MAX_AGE_H=1"
mutant schema-nao-tira-do-hard    'ev = {s: v for s, v in ev.items() if s != "banco-de-dados"}' 'pass'                                  "$SOK" 0 "$SA" "$SR"
mutant schema-todos-ou-nenhum     'if cover and all(cover):'                          'if cover and any(cover):'                        "$(DESC 'ajustar lib/sch_two.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-pasta-vira-solto    'out.append(t[i:m.end()] if t[i:m.start()].endswith("/") else m.group(0))' 'out.append(m.group(0))' "$(DESC 'ajustar lib/sch_dir.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-texto-so-o-primeiro 'for w in db_refs(blob, is_test):'                 'for w in db_refs(blob, is_test)[:1]:'            "$(DESC 'ajustar lib/sch_txt2.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-ast-so-o-primeiro   'for w in db_refs(t, is_test):'                   'for w in db_refs(t, is_test)[:1]:'               "$(DESC 'ajustar lib/sch_att.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-prosa-reaparece     'if s not in ev_all] + sch'                        'if s not in ev] + sch'                           "$(DESC 'ajustar lib/sch_ok.py que abre um sqlite')" 0 '\[shared/data/queue\.db\]", "mole-banco-com-schema:shared/data/queue\.db"\]\}$' "$SR"
mutant schema-info-sem-teto       'names[:MOLE_INFO_MAX]'                            'names'                                           "$(DESC 'ajustar lib/sch_many.py')" 0 'm6\.db", "mole-banco-com-schema-mais:1"' "$MD WA_NODE_SCHEMA_RECEIPT=$T/rcpt-sete.json"
# ga-t00j8kf: caminho absoluto / ~/ que TERMINA em shared/data/<banco do recibo>. (sch_abs_data — …/data/queue.db — e sch_abs_two são casos de regressão, sem mutante próprio)
mutant schema-abs-nao-chega       'if ab and ab.group(1) in dbs:'                     'if False:'                                       "$(DESC 'ajustar lib/sch_abs.py')" 0 "$SA" "$SR"
mutant schema-abs-ignora-recibo   'if ab and ab.group(1) in dbs:'                     'if ab:'                                          "$(DESC 'ajustar lib/sch_abs_out.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-abs-sem-fronteira   $'(?:[^\\s\\"\']+/)?(shared/data/'                   $'(?:[^\\s\\"\']+)?(shared/data/'                   "$(DESC 'ajustar lib/sch_abs_dir.py')" 10 'moles:banco-de-dados' "$SR"
mutant schema-abs-sem-til         '(?:/Users/[\w.\-]+|~)/(?:'                         '(?:/Users/[\w.\-]+)/(?:'                         "$(DESC 'ajustar lib/sch_tilde.py')" 0 "$SA" "$SR"
mutant schema-abs-sem-users       '(?:/Users/[\w.\-]+|~)/(?:'                         '(?:~)/(?:'                                       "$(DESC 'ajustar lib/sch_abs.py')" 0 "$SA" "$SR"
mutant schema-evid-corta-48       'if slug == "banco-de-dados" else what[:EVID_CLIP]' 'if False else what[:EVID_CLIP]'          "$(DESC 'ajustar lib/sch_abs.py')" 0 "$SA" "$SR"
mutant schema-info-sem-corte      'evid_clip(w)) for s in MOLE_SLUGS for f, w in ev_all.get(s, [])]' 'w) for s in MOLE_SLUGS for f, w in ev_all.get(s, [])]' "$(DESC 'ajustar lib/sch_abs.py')" 0 '\[/Users/athos/gt/whatsapp_automation/shared/data/\]", "mole-banco-com-schema:shared/data/queue\.db"\]\}$' "$SR"
mutant schema-irma-sem-corte      'evid_clip(w)) for s in MOLE_SLUGS for f, w in evsoft.get(s, [])]' 'w) for s in MOLE_SLUGS for f, w in evsoft.get(s, [])]' "$(DESCI wa-molp3.2 'corrigir o caso de borda')" 0 'mole-evidencia-irma:banco-de-dados=lib/mole_sibabs\.py\[/Users/athos/gt/whatsapp_automation/shared/data/\]' "$MD"
mutant schema-evid-sem-marca     'what[:EVID_DB_KEEP] + "…")' 'what[:EVID_DB_KEEP])'  "$(DESC 'ajustar lib/sch_abs_long.py')" 10 "$SM" "$SR"
mutant schema-evid-teto-299       'len(what) <= EVID_DB_KEEP' 'len(what) <= EVID_DB_KEEP - 1'  "$(DESC 'ajustar lib/sch_abs_300.py')" 0 "$SA" "$SR"
# o resíduo no TMPDIR: o mutante que não apaga a árvore tem de deixar item para trás (senão o teste de "sem resíduo" passaria mesmo sem a limpeza)
if mk_mutant sem-limpeza 'shutil.rmtree(root, ignore_errors=True)' 'pass'; then
  left=$(tmp_residue "$T/mut-sem-limpeza.py")
  [ "${left:-0}" -ge 1 ] && ok "mutante sem-limpeza morreu" || bad "mutante sem-limpeza SOBREVIVEU (sem apagar a árvore o TMPDIR ficou com $left item(ns))"
else bad "mutante sem-limpeza: o trecho original não existe (o classificador mudou? atualize o mutante)"; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
