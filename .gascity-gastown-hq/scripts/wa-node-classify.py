#!/usr/bin/env python3
"""wa-node-classify.py — a bead do WA roda no nó Hetzner (código + testes, sem banco real) ou só no mini? (ga-2hd02v.1.10)

Contents
  Regra · Três estados · Como decide · Códigos de saída · O que NÃO faz · Limites

REGRA (Athos, 18/10): dado de lead/cliente não vai ao nó. Esta classificação decide ONDE a bead roda; o que PODE chegar ao nó quem decide é o filtro do rsync + o espelho git
  (hetzner-rsync-filter.wa.txt), e isso não muda aqui. Classificar errado custa uma bead que falha/trava no nó e volta ao mini; classificar certo é o que tira carga do mini.

TRÊS ESTADOS (sempre): node = li tudo e há prova de que é código + teste que o nó tem / mini = li e há prova de que precisa do mini / unknown = não consegui ler ou não há prova nenhuma.
  Só `node` manda a bead ao nó. `mini` e `unknown` rodam onde sempre rodaram: erro de leitura, filtro ilegível, rsync mudo ou canário errado caem em `unknown` (estado inerte), nunca em `node`.

COMO DECIDE (a 1ª regra que casa vale; tudo é lido da bead, nada é gravado nela):
  1. entrada que não é um objeto de bead (JSON ilegível, sem id/título, texto grande demais)      -> unknown
  2. etiqueta `node:mini` (decisão humana), etiqueta `exec:manual` (um humano executa à mão; ga-qkc02kk) ou tipo epic -> mini
  3. DURAS (nem `node:ok` vence): (a) todo caminho de ARQUIVO citado na bead (forma dir/arq.ext, extensão da lista PATH_RE, maiúscula ou minúscula) passa pelo filtro REAL do rsync (um
     `rsync -n` sobre uma árvore temporária com os caminhos citados + 3 canários; canário errado = unknown) e pela lista mac-only, porque o nó simplesmente não tem o arquivo; caminho
     absoluto, `..`, `~/...`, `$VAR/...` ou fora do formato; mais de 40 caminhos; EXCEÇÃO (ga-2hd02v.3): um `.md` que o rsync não lista (docs/, DESIGN.md...) chega ao nó pelo ESPELHO git, que
     entrega tudo menos o que a varredura de CONTEÚDO sinalizou; então ele deixa de ser "fora do filtro" se (i) o filtro do rsync não o NEGA por regra (segredo, dado, pasta que nunca sai:
     shared/, logs/...) e (ii) o filtro que o espelho serve (`hetzner-mirror.sh spec-out`, só com a varredura em dia) também não o nega. Espelho ilegível, em atualização ou com canário errado
     = volta à regra acima (mini) e `info` leva `espelho-ilegivel:<motivo>`; json/txt/yaml... nunca ganham a exceção (é onde mora dado com nome neutro). O `.md` entregue vai em `info` como
     `via-espelho:<caminho>`; ele não conta como prova (nem código nem teste); (b) a bead (todos os campos, metadata
     incluída) tem telefone ou CPF com a forma do hetzner-pii-scan.py, porque o TEXTO da bead viaja ao nó e dado de lead não pode ir junto                               -> mini
     EVIDÊNCIA ≠ DEPENDÊNCIA (ga-t05a1z9): a bead cita banco/log/json como PROVA medida ("medido em queue.db"), não como algo que o código leia para ser construído ou testado. Um caminho que o nó não recebe
     (o filtro o segura, ou ele veio fora do formato: absoluto, `~/`, `$HOME/`, molde `<data>-x.json`) deixa de ser duro e vira `info` `evidencia-de-dado:<caminho>` quando (i) é arquivo de dado/log: extensão
     EVIDENCE_EXT, ou qualquer extensão que não seja código/.plist/.sql/.env dentro de uma pasta data/dados/logs; (ii) o nome NÃO parece segredo (SECRET_*, inclui português: segredo, chave, senha...); e (iii) a bead
     cita >=1 arquivo de CÓDIGO que o filtro deixa passar (nome solto que não existe na árvore não conta). Um `.md` que o rsync não nega por regra mas o espelho RETÉM (a varredura de conteúdo achou telefone/CPF nele:
     docs/data_dictionary.md tem 38 telefones e 4 CPFs) segue a mesma regra como `evidencia-de-doc:<caminho>` — e NUNCA vai ao nó. Espelho ilegível não retém nada: o doc segue duro. Sem código citado, código fora do
     filtro, nome com cara de segredo e `.plist`/`.sql`/`.env` seguem duros como antes; telefone/CPF no texto (b) continua duro e vence a evidência. O dado em si continua sem ir ao nó: quem garante é o filtro do
     rsync + a varredura do espelho, que não mudam aqui. O token de evidência também sai do texto das MOLES (regra 4), do mais longo ao mais curto: `queue.db` citado não é `moles:banco-de-dados` e
     `/Users/.../x.db` citado não é `moles:host-mac`.
     ÂNCORA DERIVADA (ga-qkc02kk): a bead que cita SÓ dado/log (nenhum código citado) e cujo segurado inteiro seria evidência ganha o "código citado" que a regra 7 acharia — o que ela NOMEIA sem caminho ou que as irmãs tocaram
     (anchor_code), pelos MESMOS filtros (rsync, mac-only). Com âncora o dado vira `info` (`evidencia-ancorada-em-derivado:N`) e a prova (teste) ainda é exigida adiante (regras 6-7). Sem âncora — nada derivado, derivado demais
     (>10 arquivos), código que o nó não recebe (`ancora-derivada-fora-do-no`) ou leitura que falhou (`ancora-derivada-ilegivel:<motivo>`) — o dado segue duro. Telefone/CPF e só-no-Mac já são duros e impedem a tentativa.
  4. MOLES (recurso vivo: banco real, credencial, host Mac) POR EVIDÊNCIA NO CÓDIGO (ga-qkc02kk). A palavra escrita na bead ("banco", "token", "osascript") é PROSA e só informa. O portão é o ÚLTIMO (depois da prova das regras
     5-8): o `node` que a prova produz — menos o de `node:ok`, decisão humana que ignora as moles (`moles-ignoradas`, pela palavra) — é lido no CÓDIGO dos arquivos da prova em origin/main (`git show`, nunca a árvore de trabalho): o que
     a bead cita, o que ela NOMEIA (regra 7a), o código que o teste citado importa (regra 8) e os testes. Python: só o código executável, por `ast` (docstring e comentário não contam); sh/js/ts e Python que não parseia: o texto sem as
     linhas de comentário (mais largo). EVIDÊNCIA: (credencial) chamada ou argv do cofre (`secret`, `bw`), módulo do cofre, arquivo de credencial (.env, credentials*.json, token.json...); (banco-de-dados) caminho de produção fixado
     (`shared/data/x.db`, `md:`, `~/`/`/Users/…/x.db`) e, fora de teste, nome de banco solto (`"queue.db"`); (host-mac) osascript/launchctl/security/adb, perfil do Chrome do Mac. NÃO são evidência: variável de ambiente com nome de token,
     `sqlite3.connect(variavel)`, `import secrets` (stdlib), `/Users/…` sozinho, nome de banco solto num TESTE (ele cria o seu em tmp). TRÊS ESTADOS: leu e achou -> `moles:<slug>` -> mini (mesmo sem palavra); leu e não achou -> a palavra só
     vai em `info` (`mole-so-em-prosa:<slug>`); NÃO consegui ler (git, arquivo > 1 MB: `mole-ilegivel:<motivo>`) ou nada que exista em origin/main para ler (tudo novo: `mole-sem-arquivo-lido`) -> volta a palavra e ela bloqueia, como antes.
     Arquivo NOVO (ainda não está em origin/main) não soma evidência e não bloqueia, se ao menos UM existente foi lido (`mole-arquivo-novo:N`). Código que só as IRMÃS tocaram (regra 7b) é palpite: é lido e a evidência dele só INFORMA
     (`mole-evidencia-irma:`), e se não der para lê-lo é só a nota `mole-irma-ilegivel`. Sem prova nenhuma o veredito é `unknown` (antes a palavra o fazia `mini`) e a palavra vai em `info` (`palavra-mole:<slug>`).
     INFORMATIVAS (produção/deploy, tela, lead, cliente, terreno, envio...): vocabulário do produto e da entrega, NÃO bloqueiam; vão para `info`, que o Pilot grava no jsonl da sombra
     para medir o acerto antes de ligar. MEDIDO (19/10, 400 beads WA fechadas): bloqueando por elas, 0 de 400 passavam; sem bloquear, ~4% citam teste + código sem caminho duro.
     Quem segura o resíduo é o que não depende de palavra: caminho pelo filtro real, telefone/CPF no texto, e o gate depois.
  5. prova positiva: >=1 teste citado (caminho tests/ ou test_*.py que o filtro deixa passar) E >=1 arquivo de código citado que o filtro deixa passar -> node, basis `text`;
     `node:ok` dispensa a prova (as duras já passaram) -> node, basis `label`; sem prova -> 6
  6. TESTE DERIVADO (ga-2hd02v.3.15; só com código citado e NENHUM teste citado; uma prova mais fraca que a 5, por isso basis próprio e freios próprios): o código citado tem de existir em
     origin/main do repo do WA (o que o espelho entrega ao nó) e ter um teste que o repo JÁ tem: arquivo tests/**/test_<módulo>.(py|js|cjs|mjs) ou test_<módulo>_*.(...), em que <módulo> é o nome
     do arquivo de código sem a extensão (>=5 letras, nada genérico como utils/config), E cujo CONTEÚDO cita o módulo como palavra inteira (nome parecido sozinho não prova). Teste que pertence a um
     módulo de nome mais longo que também existe (test_bar_service_extra_* é de bar_service_extra, não de bar_service) não conta. O teste ainda tem de passar pelo filtro do rsync, fora da lista
     mac-only e fora do que a varredura de conteúdo do espelho segura, porque "teste que o nó tem" é o que vale. Nada é inferido para código que o texto não cita. Achou -> node, basis `derivado`
     6b TESTE IMPORTADOR (ga-qkc02kk): código SEM teste de nome ganha os testes de `tests/` que o IMPORTAM — `git grep -w <módulo>` acha candidatos (até 60) e só conta o `import` estático (Python por `ast`; JS por require/import relativo)
     que resolve para O MESMO arquivo; citar o nome numa string ou comentário não conta; candidato que não parseia é pulado e contado (`teste-importador-nao-parseou:N`). Passa pelos mesmos filtros do teste de nome (rsync, mac-only, espelho) e o par
     sai em `info` como `teste-importador:<código>=<teste>`. Só roda para código que não achou teste de nome; git/grep/leitura que falha -> unknown com `teste-derivado-ilegivel`.
     Achou -> node, basis `derivado` (`info`: teste-derivado:<código>=<teste>); mas se o texto tem palavra informativa de envio de WhatsApp (o freio de DERIVED_BLOCK_INFO; `dado-de-lead` saiu em ga-2hd02v.3.21) -> mini, `freio-derivado:<palavras>`.
     Não achou -> unknown. Repo/git/espelho ilegível -> unknown com `info` `teste-derivado-ilegivel:<motivo>`; nunca vira node.
  7. CAMINHO DERIVADO (ga-2hd02v.3.20; só quando a bead NÃO cita nenhum arquivo de código — nome solto com extensão de código que não existe em lugar nenhum da árvore lida, o `part.py` de um script de
     diagnóstico, não conta como citado: `info` `caminho-solto-fora-da-arvore:<nome>`, ga-2hd02v.3.22; medido 30/10: 13 de 30 beads sondadas caíam em unknown `sem-prova-de-codigo-e-teste` porque o texto NOMEIA o módulo mas
     não escreve o caminho): o caminho sai do próprio repo do WA em origin/main, nunca de palpite. (a) NOMES: palavra com `_` ou `-` no texto (ficha_donos, form-fill; maiúscula vale; até 30 por bead) que é o nome
     de arquivo de código (sem a extensão, >=5 letras, nada genérico) na árvore do repo; um nome com mais de 3 arquivos é ambíguo (`info`: caminho-derivado-ambiguo:<nome>=N) e não deriva nada; palavra colada a
     `/` ou a uma extensão é caminho, não nome. CÓPIA DE BACKUP (ga-2hd02v.3.22): candidato cuja PASTA tem a palavra bak/backup/backups/archive/archived (`lib.bak-20260313-200326/`, `archive/`; `old`/`orig`
     não, são nomes de pasta viva) e que tem o homônimo VIVO (mesmo nome de arquivo, pasta sem essa palavra) é IGNORADO, não freado, e o vivo segue como candidato (`info`: caminho-derivado-backup-ignorado:N); a ambiguidade
     conta só os vivos. Só há a cópia -> como antes: deriva e o filtro a freia. Não se generalizou para "ignora o que está fora do filtro": isso viraria o freio em preferência. (b) IRMÃS: os arquivos de código tocados pelos commits `fix|feat(<id>)` das beads de MESMO PAI (o campo `parent` ou o id sem o último `.N`; até 40 commits dos últimos 45 dias, WA_NODE_SIBLING_DAYS; um `git log`
     com prazo próprio, WA_NODE_SIBLING_TIMEOUT, 15 s) que ainda existem na árvore. Mais de 10 arquivos derivados no total = nenhum (`caminho-derivado-demais:N`; é palpite largo). Os caminhos derivados passam pelos MESMOS
     filtros dos citados, sem afrouxar nada: filtro do rsync (fora dele -> mini `caminho-derivado-fora-do-filtro:<p>`), lista mac-only (mini `caminho-derivado-so-no-mac:<p>`), as moles e o PII da regra 3/4 (que já rodaram antes)
     e o freio de envio da regra 6 (mini `freio-derivado:envio-whatsapp`). A prova do teste é a mesma da regra 6 (o teste que o repo já tem para o código derivado) ou, se a bead cita o teste, o próprio teste citado.
     Achou -> node, basis `derivado`, motivo `prova-caminho-derivado:N-teste(s)+M-codigo(s)` (`info`: caminho-derivado:<nome:X|irmas>=<caminho>, teste-derivado:<código>=<teste>). Nada derivado ou nenhum teste -> unknown como antes.
     Falha de leitura (repo, git, rsync, mac-only, espelho, git log das irmãs sem resposta) -> unknown com `info` `caminho-derivado-ilegivel:<motivo>`; "falhou" nunca é "vazio" e nunca é node (nem pela regra 8: bead que cita teste e cuja regra 7 não leu fica unknown). Custo: os `git ls-tree`/`git log` só
     rodam com nome ou pai para consultar; o `git log` das irmãs fica num cache por pai (6 h; o cache nunca decide: o conteúdo dele passa pela árvore e pelos filtros, e cache ilegível/vencido/de outro pai é recalculado);
     o JSON leva `custo` ({ms, derivacao_ms, cache}) e o Pilot o grava na linha da sonda. NÃO há LLM nem `recall` por sonda: o recall de beads fechadas parecidas levou >120 s numa consulta sob load 80 (medido), então a
     fonte "3 beads parecidas" do pedido original NÃO foi implementada. O cache por (id, updated_at) do veredito já existe no dispatcher (memo da passada do nó); o cache daqui é só o do `git log` das irmãs.
  8. CÓDIGO DERIVADO DO TESTE (ga-2hd02v.3.21; só quando a bead cita >=1 teste e NENHUM código e a regra 7 LEU e não derivou nada; regra 7 que não conseguiu ler fica unknown e a 8 não roda): o código é o que o próprio TESTE importa. Lê-se o teste citado em origin/main
     (`git show`, nunca a árvore de trabalho; teste que não está lá é novo e não há o que ler) e só os `import`/`require` ESTÁTICOS contam: Python por `ast` (nada é executado; `import a.b`, `from a.b import c`, relativo `from .x import y`;
     o nome é procurado na raiz, em lib/, daemons/ e scripts/ — as raízes do pytest.ini e dos `sys.path.insert` dos testes do WA — e na pasta do teste e na de cima) e JS/CJS/MJS/TS por `require('./x')`/`import … from './x'`/`import('./x')`
     (só caminho relativo; pacote npm e builtin não são do repo). Entram só arquivos de código (py/sh/js/mjs/cjs/ts, fora de tests/) que EXISTEM em origin/main; stdlib e pacote de terceiros não casam arquivo nenhum e somem sozinhos.
     Os arquivos achados passam pelos MESMOS filtros do citado, sem afrouxar nada: um que o filtro do rsync nega -> mini `codigo-do-teste-fora-do-filtro:<p>`; um da lista mac-only -> mini `codigo-do-teste-so-no-mac:<p>` (o teste não roda no nó sem
     o módulo que importa); mais de 10 -> nenhum (`codigo-do-teste-demais:N`); o freio de envio da regra 6 vale. Achou e passou -> node, basis `derivado`, motivo `prova-codigo-derivado-do-teste:N-teste(s)+M-codigo(s)` (`info`: codigo-do-teste:<teste>=<código>).
     Nada importado do repo -> unknown SEM nota (vazio é legítimo). Falha de leitura (repo, git show, teste que não parseia, rsync, mac-only) -> unknown com `info` `codigo-do-teste-ilegivel:<motivo>`; "falhou" nunca é "vazio" e nunca é node.

CÓDIGOS DE SAÍDA: 0 node · 10 mini · 11 unknown · 2 uso. A linha de stdout é um JSON: {"verdict","basis","reasons":[...],"paths":[...],"tests":[...],"custo":{"ms","derivacao_ms","cache"},"info":[...]}; basis = label | text | derivado | "" (só o node tem).
O QUE NÃO FAZ: não lê dado, não abre o nó, não toca o Dolt, não escreve na bead. Lê só stdin (o JSON do `bd show --json`), o filtro, a lista mac-only, (só com `.md` fora do rsync) o filtro que o espelho serve e (só com código citado sem teste citado) a árvore e o conteúdo dos TESTES do repo do WA em origin/main, por `git ls-tree`/`git grep`: nunca a árvore de trabalho; (só sem código citado, regra 7) a árvore de código do repo e o `git log` dos commits das beads irmãs; (só com teste citado e sem código, regra 8) o texto dos testes citados, por `git show` em REPO_REF; (só quando há `node` com prova, regra 4) o texto dos arquivos da prova, por `git show` em REPO_REF, e (regra 6b) os testes que citam o módulo. ESCREVE uma única coisa: o cache do `git log` das irmãs (WA_NODE_CACHE, padrão <cidade>/.gc/cache/wa-node-classify; escrita atômica, opcional: sem ele o classificador só fica mais lento).
LIMITES: a evidência das moles é heurística de TEXTO sobre o código dos arquivos da prova: não segue import em cadeia (um módulo limpo que importa outro que abre o banco passa; o teste vermelho no nó devolve a bead ao mini pelo gate), não vê `sqlite3.connect(variavel)` cujo valor vem de fora, nem evidência depois do 4000º caractere de UMA string; no Python que parseia também não vê o comando do cofre no MEIO de uma linha de shell (`env X=1 secret k`: só vale no começo da string ou depois de `; | & (`, para a prosa "the secret key…" não virar cofre), literal bytes, o binário numa variável montada fora do arquivo nem argv montado em pedaços (medido nos 6202 .py do WA: ver o runbook, "Limites"); nome de banco solto é lido como banco de produção (pode ser um banco temporário do módulo: erra para o lado do mini). A exceção do espelho confia na varredura de conteúdo (>=20 telefones ou >=3 CPFs distintos por arquivo): lista pequena, nome, e-mail e CNPJ num `.md` passam; vale o mesmo resíduo do bloco 3b do filtro. É heurística de TEXTO sobre a bead; o texto pode omitir que o teste abre um banco. NÃO são extraídos: pasta sem arquivo (`data/`), arquivo sem nome (`.env`), extensão fora da lista, nome com
  sufixo (`x.py.bak` não vira `x.py`). Para esses a regra 3a não age; quem segura o dado é o filtro do rsync (o nó nunca o recebe) e, no caso de `.env`/`.db`, a palavra mole da regra 4. O resíduo cai no nó como teste vermelho e a bead volta ao mini pelo gate (custo, não vazamento:
  o dado não chega ao nó de qualquer jeito). A lista de palavras moles é deliberadamente larga (o vocabulário do WA é todo de lead/terreno): na dúvida a bead fica no mini, como hoje.
  A regra 8 prova que o teste citado IMPORTA o módulo, não que o módulo seja o que a bead quer mudar nem que o teste cubra a mudança; também não segue import em cadeia (o que o módulo importa), nem o `__init__.py` do pacote pai, nem carga dinâmica
  (`importlib`, `__import__`, `spec_from_file_location`, `subprocess`): o que faltar no nó cai como teste vermelho e a bead volta ao mini pelo gate. A regra 6 prova que existe um teste do módulo que o cita; NÃO prova que ele cobre a mudança da bead, nem que roda sem recurso vivo (pode abrir banco, rede ou Chrome, ou dar skip e ficar verde sem provar nada): isso cai no nó como teste
  vermelho/skip e a bead volta ao mini pelo gate. Por isso o basis é `derivado` e não `text`: quem for ligar o modo auto pode tratar os dois de um jeito diferente. Plano, comentário e ctx-check NÃO entram: o plano (design/notes/acceptance_criteria)
  já é lido, o ctx-check só grava etiqueta e comentário de lacuna, e o worker do nó não recebe comentário (ga-2hd02v.10).
"""
import ast
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
FILTER = os.environ.get("WA_NODE_FILTER", os.path.join(HERE, "hetzner-rsync-filter.wa.txt"))
MAC_ONLY = os.environ.get("WA_NODE_MAC_ONLY", os.path.join(HERE, "hetzner-mac-only.txt"))
RSYNC = os.environ.get("WA_NODE_RSYNC", "rsync")
try:
    RSYNC_TIMEOUT = max(1, int(os.environ.get("WA_NODE_RSYNC_TIMEOUT", "30")))   # número ilegível -> 30 (o padrão), nunca um crash na importação
except ValueError:
    RSYNC_TIMEOUT = 30
MIRROR = os.environ.get("WA_NODE_MIRROR", os.path.join(HERE, "hetzner-mirror.sh"))   # `spec-out <rig>`: o filtro de dados que o espelho git serve ao nó (o que o wa-worker-remote de fato recebe)
MIRROR_RIG = os.environ.get("WA_NODE_MIRROR_RIG", "whatsapp_automation")
GIT = os.environ.get("WA_NODE_GIT", "git")
try:
    MIRROR_TIMEOUT = max(1, int(os.environ.get("WA_NODE_MIRROR_TIMEOUT", "20")))
except ValueError:
    MIRROR_TIMEOUT = 20
EX_NODE, EX_MINI, EX_UNKNOWN, EX_USAGE = 0, 10, 11, 2
MAX_IN = 1_000_000      # bytes de stdin
MAX_TEXT = 200_000      # caracteres de texto da bead
MAX_PATHS = 40
CODE_EXT = ("py", "sh", "js", "mjs", "cjs", "ts", "css")   # as mesmas do bloco 3a do filtro; quem manda é o filtro, isto só decide o que é "arquivo de código" na prova positiva
EXTS = "py|sh|js|mjs|cjs|ts|css|json|jsonl|yaml|yml|md|html|sql|plist|txt|csv|db|sqlite3?|xlsx|parquet|toml|ini|cfg|log|pdf|env"
PATH_RE = re.compile(r"(?<![\w/.\-~$])((?:/?[\w.\-]+/)*[\w\-]+(?:\.[\w\-]+)*\.(?:" + EXTS + r"))(?![\w\-]|\.\w)", re.IGNORECASE)   # `x.py.bak`/`x.py-old` não viram `x.py`; ponto final de frase continua valendo
HOME_RE = re.compile(r"(?<!\w)[~$][\w{}]*/(?:[\w.\-]+/)*[\w.\-]+\.(?:" + EXTS + r")(?![\w])", re.IGNORECASE)   # ~/x.json, $HOME/x.py: o nó não tem o home do Mac
SAFE_SEG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,80}$")
TEST_RE = re.compile(r"(^|/)tests?/|(^|/)test_[^/]*\.py$|_test\.py$|\.selftest\.sh$")
REPO_ABS = "/Users/athos/gt/whatsapp_automation/"
CANARY_OK = "tests/test_zz_wa_node_canary.py"         # o filtro TEM de deixar sair
CANARY_NO = ("data/zz_wa_node_canary.json", ".env", "credentials_zz.json")   # o filtro TEM de segurar
# só TEXTO neutro (documentação) pode chegar ao nó pelo espelho sem estar na lista do rsync; json/jsonl/txt/yaml... ficam de fora: é onde mora dado com nome neutro (docs/auto_response/ab_results/*.json)
MIRROR_TEXT_EXT = ("md",)
CANARY_DOC = "docs/zz_wa_node_canary.md"                             # a visão "só negações" do filtro e o espelho TÊM de deixar passar
CANARY_OPEN_NO = ("shared/zz_wa_node_canary.md", "logs/zz_wa_node_canary.md")   # pasta que nunca sai (Seção 3): a visão "só negações" TEM de segurar mesmo sendo .md
CANARY_MIRROR_NO = ("data/zz_wa_node_canary.json", "zz_wa_node_canary.db", ".env")   # o espelho TEM de segurar (as mesmas famílias que a Seção 1 / pastas de dado)
MIRROR_MIN_RULES = 20                                                # a Seção 1 traduzida tem mais que isto; menos = filtro cortado
# evidência ≠ dependência (ga-t05a1z9): a bead cita um banco, log ou doc como PROVA medida ("medido em queue.db"), não como algo que o código precise ler para ser construído ou testado. Caminho de DADO/LOG que o nó
# não recebe deixa de ser regra dura e vira `info`, mas só se a bead cita >=1 arquivo de CÓDIGO que o filtro deixa passar. O dado em si continua sem ir ao nó (quem garante é o filtro do rsync + a varredura do espelho,
# que não mudam aqui) e telefone/CPF no texto continua duro. Código, .env/.plist/.sql e nome com cara de segredo (SECRET_*, em português também) nunca são evidência: seguem duros.
EVIDENCE_EXT = ("db", "sqlite", "sqlite3", "log", "json", "jsonl", "csv", "parquet", "xlsx")
EVIDENCE_DIRS = ("data", "dados", "logs")                            # pasta de dado/log: um SEGMENTO do caminho (shared/data/x.db tem o `data`)
NOT_EVIDENCE_EXT = CODE_EXT + ("sql", "plist", "env")                # código e config de host/segredo que o nó não recebe são dependência de verdade, mesmo dentro de uma pasta de dado
SECRET_PREFIX = ("segred", "chave", "senha", "secret", "token", "credenc", "credential", "passw", "privat", "privad", "oauth", "jwt", "cookie", "keystore", "apikey", "auth", "login", "cert")
SECRET_WORD = ("key", "keys", "pem", "p12", "pfx", "env", "pass", "pwd", "netrc")   # palavra INTEIRA: `key` casa map_key.json mas não monkey_patch.json
MAX_EVIDENCE_INFO = 8                                                # evidências nomeadas em `info`; o resto vira `evidencia-de-dado-mais:N`
# regra 6 (teste derivado, ga-2hd02v.3.15): o teste que o repo do WA já tem para o código citado
REPO_DIR = os.environ.get("WA_NODE_REPO", REPO_ABS.rstrip("/"))      # o repo do WA no mini: dele saem a árvore e o conteúdo dos testes
REPO_REF = os.environ.get("WA_NODE_REPO_REF", "origin/main")         # o que o espelho entrega ao nó; nunca a árvore de trabalho (o que não está commitado o nó não tem)
try:
    REPO_TIMEOUT = max(1, int(os.environ.get("WA_NODE_REPO_TIMEOUT", "20")))
except ValueError:
    REPO_TIMEOUT = 20
DERIVE_EXT = ("py", "sh", "js", "mjs", "cjs", "ts")                  # só código com essas extensões ganha teste por nome (um .css citado não ganha), e só os módulos delas contam como "módulo de nome mais longo"
TEST_FILE_RE = re.compile(r"^test_(.+)\.(?:py|js|cjs|mjs)$")         # tests/**/test_<módulo>[_<sufixo>].<ext>; os 5 test_*.sh do WA ficam de fora (teste de shell: esta regra só conhece py/js)
STEM_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
MIN_STEM = 5                                                         # nome curto (db, auth, app) casa teste de mil coisas
GENERIC_STEMS = frozenset(("utils", "helpers", "helper", "common", "config", "settings", "server", "client", "models", "routes", "index", "shared", "setup", "types", "tools", "utility", "utilities", "runner", "worker", "daemon"))
MAX_DERIVED_PER_STEM = 25                                            # testes candidatos por módulo (ordem alfabética); acima disso o excesso nem é lido
MAX_DERIVED_TESTS = 100                                              # candidatos no total, para o rsync -n e o git grep ficarem curtos
DERIVED_BLOCK_INFO = ("envio-whatsapp",)                             # palavra informativa que, só para a prova derivada (mais fraca), manda ao mini. `dado-de-lead` saiu (ga-2hd02v.3.21): é regex de VOCABULÁRIO (lead(s), cliente(s), cpf, cnpj, telefone(s), celular(es), conversa(s), dump, csv, xlsx, parquet, terreno(s), lote(s), construtora(s), proprietari*), não de dado, e segurava 18 beads (ga-2hd02v.3.17) — 4 das 15 P0/P1 WA aprovadas (30/10). O dado em si é barrado por portões que não mudam: filtro do rsync, varredura PII do espelho, dado-no-texto (telefone/CPF no JSON da bead — NOME, e-mail, CNPJ e endereço no texto NÃO o acionam: esse freio de vocabulário deixou de existir por pedido do Mayor) e as moles; banco e credencial já bloqueiam antes
NAME_RE = re.compile(r"(?<![\w/.\-~$])([A-Za-z][A-Za-z0-9]*(?:[_\-][A-Za-z0-9]+)+)(?![\w/]|\.\w)")   # `ficha_donos`, `form-fill`: nome de módulo/tela/daemon SEM caminho (o que tem pasta ou extensão é caminho e já foi lido)
MAX_NAME_TOKENS = 30                                                 # nomes distintos lidos de uma bead
MAX_FILES_PER_NAME = 3                                               # um nome que casa mais arquivos que isto é ambíguo: não deriva nada dele
BACKUP_WORDS = frozenset(("bak", "backup", "backups", "archive", "archived"))   # palavra de PASTA que marca cópia: `lib.bak-20260313-200326/` e `archive/` existem no repo do WA, o resto é o mesmo nome por extenso; `old`/`orig` ficam de fora porque pasta viva pode ter esse nome
MAX_DERIVED_CODE = 10                                                # arquivos de código derivados no total; acima disso a bead não é sobre um módulo só: não deriva nada
# regra 8 (código derivado do teste, ga-2hd02v.3.21): o que o teste citado importa
MAX_TEST_BYTES = 1_000_000                                           # teste maior que isto não é analisado (o git já o devolveu inteiro, mas não passa pelo parse): ilegível, nunca "sem import"
IMPORT_ROOTS = ("", "lib", "daemons", "scripts")                     # onde um `import x` do WA procura: a raiz e lib/ (pytest.ini: pythonpath = . lib) e daemons/ e scripts/ (os sys.path.insert dos testes); mais a pasta do teste e a de cima
JS_TEST_EXT = ("js", "cjs", "mjs", "ts")                             # testes de que se lê `require`/`import`; teste .sh e o resto não têm o que ler (vazio legítimo)
JS_IMPORT_RE = re.compile(r"""(?:\brequire\s*\(|\bimport\s*\(|\bfrom\s+|\bimport\s+)\s*(['"])([^'"\n]+)\1""")   # require('x') / import('x') / import a from 'x' / import 'x' / export … from 'x'
PARENT_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*(?:\.[0-9]+)*$")    # id de bead (com níveis `.N`): o pai vai no padrão do `git log --grep`, então só esta forma entra
SIBLING_MAX_COMMITS = 40                                             # commits das irmãs lidos (o git para de andar no histórico ao achar tantos)
SIBLING_MAX_NAMES = 200                                              # arquivos guardados no cache por pai
try:
    SIBLING_TIMEOUT = max(1, int(os.environ.get("WA_NODE_SIBLING_TIMEOUT", "15")))   # prazo próprio do `git log` das irmãs, menor que o do check do dispatcher (30 s): estourou -> unknown com a nota, nada vai ao cache
except ValueError:
    SIBLING_TIMEOUT = 15
try:
    SIBLING_DAYS = min(3650, max(1, int(os.environ.get("WA_NODE_SIBLING_DAYS", "45"))))   # teto de 10 anos: o git, com `--since` anterior a 1970 (~30000 dias), devolve ZERO commits SEM erro — um "vazio" falso que viraria unknown sem nota; o `--grep` lê TODA mensagem de commit que anda: medido (30/10, load ~80, ~12 mil commits) 19-22 s sem limite, 6,8 s com 90 dias, 3,2 s com 30; irmã mais velha que isto não é derivada (menos prova, nunca prova errada)
except ValueError:
    SIBLING_DAYS = 45
SIBLING_TTL = 6 * 3600                                               # o cache dos arquivos das irmãs vale 6 h (vencido = recalcula; irmã nova que o cache não viu só faz derivar MENOS, nunca algo errado)
CACHE_DIR = os.environ.get("WA_NODE_CACHE", os.path.join(HERE, "..", ".gc", "cache", "wa-node-classify"))
COST = {"derivacao_ms": 0, "cache": "-"}                             # o que a regra 7 gastou nesta execução (vai em `custo` na saída): "-" sem consulta às irmãs, hit/miss/nao-gravou com
PROOF = set()    # arquivos de CÓDIGO e TESTE em que a prova desta execução se apoia (citados e derivados): é neles que as moles procuram evidência (regra 4, ga-qkc02kk)
PROOF_SOFT = set()   # código que só as IRMÃS tocaram (regra 7b): palpite de onde a bead mexe, não citação. É lido, mas a evidência dele só INFORMA (`mole-evidencia-irma`), não bloqueia
DERIVED_SRC = {}     # código derivado -> origem ("nome:<x>" ou "irmas"), preenchido pela regra 7
PROSE = []       # moles que só aparecem escritas na bead (palavra); informam, não bloqueiam quando a leitura dos arquivos de prova deu certo
NOTES = []       # notas de `info` que as funções fundas (teste importador, âncora) deixam para o fim da resposta
TEST_VIA = {}    # (código, teste) -> "importador" quando o teste veio da regra 6b (importa o módulo) e não do nome
# regra 4 (moles por EVIDÊNCIA, ga-qkc02kk): "banco", "token", "osascript" escritos na bead são PROSA; o que decide se a bead depende de recurso vivo é o que o CÓDIGO dos arquivos de prova mostra. Lê-se o texto de origin/main
# (`git show`, nunca a árvore de trabalho). Python: só o código executável, por `ast` (docstring e comentário não contam); o resto (sh/js/ts) e Python que não parseia: o texto sem as linhas de comentário (mais largo: na dúvida acha MAIS evidência).
SCAN_EXT = ("py", "sh", "js", "mjs", "cjs", "ts")                    # extensões de que se lê evidência; .css/.html não têm o que ler
# (sem teto de arquivos lidos: a prova já é limitada pelos tetos que existem — 40 caminhos citados, 100 testes derivados, 10 códigos derivados —, no pior caso ~150 `git show`, medido 2,3 s com a máquina carregada)
MAX_STR_LEN = 4000                                                   # limite de custo do regex: de UMA string só os primeiros 4000 caracteres são lidos (dado embutido, SQL gigante). PONTO CEGO conhecido: um `.db`/`osascript` depois do 4000º caractere de uma mesma string não é visto
MOLE_SLUGS = ("banco-de-dados", "credencial", "host-mac")
MOLE_INFO_MAX = 6                                                    # pares slug=arquivo nomeados em `info`; o resto vira `mole-evidencia-mais:N`
CRED_CLI = frozenset(("secret", "bw", "bws", "bitwarden"))           # argv do CLI do cofre: ["secret", "motherduck-token"] é UMA das formas do WA (87 linhas com argv exato, 57 com o CAMINHO do binário -> exec_base; linha de shell -> CRED_SHELL_RE; wrapper secret_bin()/lib.secret_cli -> CRED_CALL_RE/CRED_MOD_RE)
CRED_CALL_RE = re.compile(r"^_*(?:get_|load_|read_|fetch_|resolve_)?secret(?:_bin|_cli)?$|^_*(?:bw|bws|bitwarden)(?:_\w+)?$", re.I)   # `_secret("x")`, `secret(...)`, `bw_get`; `secrets.token_hex` (stdlib) não casa
CRED_MOD_RE = re.compile(r"(?:^|\.)(?:_?bitwarden\w*|keychain\w*|credentials?\w*|_?secret(?:_bin|_cli)?)(?:\.|$)", re.I)   # módulo do cofre/chaveiro; `secrets` (stdlib: números aleatórios) NÃO casa
CRED_FILE_RE = re.compile(r"(?:^|[/\\])(?:\.env(?:\.[\w\-]+)?|credentials?[\w\-]*\.json|token\.json|client_secrets?[\w\-]*\.json|service[_\-]?account[\w\-]*\.json|[\w\-]+\.(?:pem|p12|pfx))$", re.I)   # abrir arquivo de credencial
CRED_TEXT_RE = re.compile(r"\$\(\s*secret\s+\S|(?<![\w\-])secret\s+[\"'$\w][\w\-\"']*|\bbw\s+(?:get|unlock|login)\b|bitwarden|(?<![\w/])\.env\b|credentials?[\w\-]*\.json|token\.json|client_secrets?[\w\-]*\.json", re.I)   # texto de .sh/.js e de Python que não parseia
HOST_RE = re.compile(r"\b(?:osascript|launchctl|plutil|pmset|pbcopy|pbpaste|caffeinate|screencapture)\b|Google Chrome|Chrome\.app|Application Support/Google/Chrome|/Applications/|LaunchAgents|LaunchDaemons|~/Library|remote-debugging-port|connect_over_cdp|\bbrew\s+(?:install|services|list)\b|\badb\s+(?:shell|devices|connect|push|pull|-s)\b")   # recurso do Mac do Athos que o nó não tem; `/Users/...` sozinho NÃO conta (é caminho-padrão, não recurso)
# o ramo `ast` do Python vê STRINGS soltas, não o texto: a mesma ideia escrita como linha de shell ("secret motherduck-token", "/Users/x/.local/bin/secret k") ou como caminho do executável
# precisa dar o MESMO achado que o ramo de texto (ga-qkc02kk, gate-fix 1). O comando só vale no INÍCIO da string ou depois de operador de shell (`; | & ( \``): "the secret key is missing" é prosa e não conta.
CRED_SHELL_RE = re.compile(r"(?:^\s*|[;|&(`]\s*)(?:\S*/)?(?:secret\s+(?:[\w\-\"'$][\w\-\"']*|$)|bws?\s+(?:get|list|unlock|login|logout|status|sync|secret|run)\b)|bitwarden|(?<![\w/])\.env\b|credentials?[\w\-]*\.json|token\.json|client_secrets?[\w\-]*\.json|\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:PERSISTENT\s+|TEMPORARY\s+)?SECRET\b", re.I)   # texto de UMA string de Python que parseia; o último ramo é o DDL do DuckDB (`CREATE OR REPLACE SECRET s3_x (TYPE s3, PROVIDER credential_chain)`: lib/mds_s3.py, lib/rfb_s3.py), credencial AWS que o ramo de texto só vê por acaso
HOST_SHELL_RE = re.compile(r"(?:^\s*|[;|&(`]\s*)(?:\S*/)?(?:(?:adb|osascript|launchctl|pmset|plutil|pbcopy|pbpaste|caffeinate|screencapture)\b|security\s+(?:find|add|delete|import|export|unlock|lock|list|dump|set|show|create)-[\w\-]+)")   # idem para o Mac: o executável do Mac no começo da linha
HOST_CALL_RE = re.compile(r"(?:^|_)(?:connect_over_cdp|osascript|launchctl|plutil|pmset|pbcopy|pbpaste|caffeinate|screencapture)(?:_|$)")   # NOME de chamada/módulo: `chromium.connect_over_cdp(...)`, `run_osascript(...)` (o HOST_RE de string não vê nome de função, e `\b` não separa `_`)
HOST_ARGV = frozenset(("adb", "osascript", "launchctl", "security", "pmset", "plutil", "pbcopy"))   # string que é SÓ o executável (argv[0] de subprocess)
DB_PINNED_RE = re.compile(r"shared/data/[^\s\"']*\.(?:db|sqlite3?|duckdb)\b|(?<![\w])md:[\w\-]*|/Users/[\w.\-]+/[^\s\"']*\.(?:db|sqlite3?|duckdb)\b|~/[^\s\"']*\.(?:db|sqlite3?|duckdb)\b|\.duckdb\b")   # caminho de banco de PRODUÇÃO fixado (vale em código e em teste)
DB_BARE_RE = re.compile(r"(?<![\w\-])[\w\-][\w.\-]*\.(?:db|sqlite3?|duckdb)(?![\w])")   # nome de banco solto ("queue.db", "construtoras.db"): em código conta como banco de produção (heurística: o WA monta o caminho por pedaços, "shared" / "data" / "x.db"); em TESTE é o banco que o teste cria em tmp, por isso não conta lá

# palavras do texto (sem acento, minúsculas). slug -> regex. Larga de propósito (ver LIMITES).
SOFT = (
    ("banco-de-dados", r"\b(sqlite3?|duckdb|dolt|postgres\w*|mysql|bancos?|database|wal_checkpoint|base de dados|base real|base viva)\b|\.db\b"),
    ("credencial", r"\b(tokens?|secret\w*|senhas?|password|credencia\w*|api[_ -]?key|oauth|pdpj|login|jwt|cookies?)\b|\.env\b"),
    ("host-mac", r"(/users/|\bosascript\b|\bhomebrew\b|\bbrew\b|\badb\b|\bmbp\b|\bmac ?(mini|book)\b|\bkeychain\b)"),
)
# vocabulário do produto e da entrega: só informa (ver doc). Medir na sombra se alguma deveria passar a bloquear.
INFO = (
    ("producao", r"\b(producao|prod|launchd|launchctl|plist|kickstart|daemons?|restart\w*|reinici\w*|deploy\w*|cron|crontab|backups?|s3|aws|drive|mount|rclone)\b"),
    ("tela-ao-vivo", r"\b(painel|dashboard|app\.urblink|telas?|front-?end|navegador|playwright|screenshot|browser|chrome|html)\b"),
    ("dado-de-lead", r"\b(leads?|clientes?|cpf|cnpj|telefones?|celular(es)?|conversas?|dump|csv|xlsx|parquet|terrenos?|lotes?|construtoras?|proprietari\w*)\b"),
    ("envio-whatsapp", r"\b(whatsapp|envios?|enviar|disparos?|chips?|ban|evolution|baileys)\b"),
)
# mesmas expressões do hetzner-pii-scan.py (o selftest confere que não divergiram); aqui QUALQUER uma já basta, porque é o texto da bead que viaja ao nó
PH = re.compile(r"(?<![0-9])\+?55 ?\(?[1-9][0-9]\)? ?9?[0-9]{4}-?[0-9]{4}(?![0-9])|\([1-9][0-9]\) ?9?[0-9]{4}-[0-9]{4}(?![0-9])")
CPF = re.compile(r"(?<![0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}(?![0-9])")
SOFT_RE = tuple((slug, re.compile(rx)) for slug, rx in SOFT)
INFO_RE = tuple((slug, re.compile(rx)) for slug, rx in INFO)


class Unreadable(Exception):
    """não consegui ler algo de que a decisão depende -> unknown (nunca node)."""


def norm(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)).lower()


def load_bead(raw):
    # vazio -> unknown (nada a classificar); ilegível/não-objeto/sem id e título -> unknown
    if not raw.strip():
        raise Unreadable("entrada-vazia")
    try:
        b = json.loads(raw)
    except ValueError:
        raise Unreadable("json-ilegivel")
    if isinstance(b, list) and len(b) == 1:
        b = b[0]
    if not isinstance(b, dict) or not isinstance(b.get("id"), str) or not isinstance(b.get("title"), str) or not b["id"] or not b["title"]:
        raise Unreadable("sem-id-ou-titulo")
    return b


def bead_text(b):
    parts = []
    for k in ("title", "description", "design", "acceptance_criteria", "notes"):
        v = b.get(k)
        if v is None:
            continue
        if not isinstance(v, str):
            raise Unreadable("campo-%s-nao-e-texto" % k)   # campo de tipo estranho: não adivinho o que há nele
        parts.append(v)
    text = "\n".join(parts)
    if len(text) > MAX_TEXT:
        raise Unreadable("texto-grande")                    # truncar esconderia palavra-chave: melhor não decidir
    return text


def labels_of(b):
    # ausente -> sem etiquetas; lista com algo que não é texto -> ilegível (não sei o que vale)
    lab = b.get("labels")
    if lab is None:
        return []
    if not isinstance(lab, list) or not all(isinstance(x, str) for x in lab):
        raise Unreadable("labels-ilegiveis")
    return lab


def extract_paths(text):
    """(caminhos válidos em ordem, motivos duros, caminhos FORA DO FORMATO). Caminho fora do formato seguro (absoluto, `..`, `~/`, `$VAR/`, segmento torto) NUNCA vai ao disco; quem chama decide se ele é
    motivo duro (`caminho-fora-do-formato`) ou evidência de dado (evidence_kind): aqui só se junta o que foi visto, cada texto uma vez: primeiro os `~/`/`$VAR/`, depois os demais, cada grupo na ordem em que aparece na bead."""
    seen, out, hard, odd = set(), [], [], []
    for m in HOME_RE.finditer(text):   # ~/x.json, $HOME/x.py: o nó não tem o home do Mac
        if m.group(0) not in odd:
            odd.append(m.group(0))
    for m in PATH_RE.finditer(text):
        p = m.group(1)
        if p.startswith(REPO_ABS):
            p = p[len(REPO_ABS):]
        if p.startswith("./"):
            p = p[2:]
        if p in seen:
            continue
        seen.add(p)
        segs = p.split("/")
        if p.startswith("/") or any(s in ("", ".", "..") for s in segs) or not all(SAFE_SEG.match(s) for s in segs):
            if p not in odd:
                odd.append(p)
            continue
        if len(out) >= MAX_PATHS:   # o 41º caminho válido estoura o teto; exatamente 40 ainda vale
            hard.append("caminhos-demais")
            break
        out.append(p)
    return out, hard, odd


def secretish(p):
    """True se o NOME do caminho parece segredo (segredo/chave/senha/token/credencial/.pem...). Só olha o texto do caminho. Existe porque a palavra mole `credencial` do SOFT só conhece o inglês (`secret\\w*`,
    `credencia\\w*`): `~/segredos/chave.json` não pode virar "evidência de dado" por ser .json. Na dúvida é True (o caminho segue duro, como era antes de ga-t05a1z9)."""
    toks = [t for t in re.split(r"[^a-z0-9]+", norm(p)) if t]
    return any(t.startswith(SECRET_PREFIX) or t in SECRET_WORD for t in toks)


def evidence_kind(p):
    """"dado" se `p` (um caminho que o nó NÃO recebe) é arquivo de DADO/LOG: extensão de dado (EVIDENCE_EXT) ou, com qualquer extensão que não seja código/config de host, dentro de pasta de dado/log
    (EVIDENCE_DIRS). Código, .plist/.sql/.env, caminho sem extensão e nome com cara de segredo -> "" (dependência de verdade: segue duro). Só olha o texto do caminho; não lê nada."""
    segs = p.split("/")
    base = segs[-1]
    ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
    if not ext or ext in NOT_EVIDENCE_EXT or secretish(p):
        return ""
    if ext in EVIDENCE_EXT or any(s.lower() in EVIDENCE_DIRS for s in segs[:-1]):
        return "dado"
    return ""


def sent_by_filter(paths, only_denies=False):
    """subconjunto de `paths` que o filtro REAL do rsync deixa sair. Falha em qualquer passo (filtro, rsync, canário) = Unreadable.
    only_denies: a visão "só negações" do mesmo filtro (o `- *` final vira `+ *`): sai tudo que o filtro NÃO nega por regra (Seções 1 e 3: segredo, dado, pasta que nunca sai); serve só para
    separar "o filtro nega este caminho" de "o filtro não lista este caminho" (quem decide o segundo caso é o espelho, ver mirror_reach)."""
    # filtro ausente/ilegível -> Unreadable (sem o filtro não sei o que o nó tem)
    try:
        with open(FILTER, "r", encoding="utf-8") as fh:
            ftext = fh.read()
    except OSError:
        raise Unreadable("filtro-ilegivel")
    if "- *" not in ftext:
        raise Unreadable("filtro-sem-negacao-final")
    ok_canary, no_canary = [CANARY_OK], list(CANARY_NO)
    root = tempfile.mkdtemp(prefix="wa-node-classify.")
    try:
        filt = FILTER
        if only_denies:
            # vazio/sem `- *` como ÚLTIMA regra -> Unreadable (não sei qual é o resto do filtro); falhou/ilegível ao gravar a cópia -> Unreadable (nunca "tudo sai")
            rules = [l for l in ftext.splitlines() if l.strip() and not l.lstrip().startswith("#")]
            if not rules or rules[-1].strip() != "- *":
                raise Unreadable("filtro-sem-negacao-final")
            filt = os.path.join(root, "filtro-so-negacoes.txt")
            try:
                with open(filt, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(rules[:-1] + ["+ *"]) + "\n")
            except OSError:
                raise Unreadable("filtro-so-negacoes-nao-gravou")
            ok_canary.append(CANARY_DOC)
            no_canary += list(CANARY_OPEN_NO)
        src, dst = os.path.join(root, "src"), os.path.join(root, "dst")
        os.mkdir(src)
        os.mkdir(dst)
        for p in list(paths) + ok_canary + no_canary:
            full = os.path.join(src, p)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "w").close()
        # rsync -n lista o que SAIRIA; sem resposta/rc!=0/saída vazia -> Unreadable (nunca "nada sai" por engano)
        try:
            r = subprocess.run([RSYNC, "-a", "-n", "--out-format=%n", "--filter=. " + filt, src + "/", dst + "/"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=RSYNC_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            raise Unreadable("rsync-sem-resposta")
        if r.returncode != 0:
            raise Unreadable("rsync-rc-%d" % r.returncode)
        sent = set(l for l in r.stdout.decode("utf-8", "replace").splitlines() if l and not l.endswith("/"))
        # canário: os de código/doc TÊM de sair e os de segredo/dado/pasta-que-nunca-sai não; senão o filtro ou o rsync não é o que eu penso
        if any(c not in sent for c in ok_canary) or any(c in sent for c in no_canary):
            raise Unreadable("canario-errado")
        return sent
    finally:
        shutil.rmtree(root, ignore_errors=True)


def mirror_rules():
    """as regras de NEGAÇÃO do filtro que o espelho git serve ao nó (`hetzner-mirror.sh spec-out <rig>`: Seção 1 do rsync + pastas de dado + caminhos que a varredura de CONTEÚDO sinalizou).
    Só devolve com o espelho em dia (a varredura cobre as pontas); qualquer dúvida = Unreadable, e quem chama cai no filtro do rsync, o mais estrito."""
    # script ausente / sem resposta no prazo / rc != 0 (75 = varredura ainda não cobre as pontas, 3 = não dá para confiar) -> Unreadable: nunca "o espelho deixa tudo"
    try:
        r = subprocess.run([MIRROR, "spec-out", MIRROR_RIG], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=MIRROR_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable("espelho-sem-resposta")
    if r.returncode != 0:
        raise Unreadable("espelho-rc-%d" % r.returncode)
    lines = [l for l in r.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
    # saída vazia / sem a raiz `/*` / linha que não é negação (`!regra`) / poucas regras / sem as famílias de dado -> Unreadable: filtro cortado ou de outro formato não é "nada negado"
    if not lines or lines[0] != "/*" or any(not l.startswith("!") or len(l) < 2 for l in lines[1:]):
        raise Unreadable("espelho-formato")
    rules = [l[1:] for l in lines[1:]]
    if len(rules) < MIRROR_MIN_RULES or any(c not in rules for c in ("*.csv", "*.db", "*.parquet", ".env", "*.duckdb*")):
        raise Unreadable("espelho-filtro-cortado")
    return rules


def mirror_denied(rules, paths):
    """subconjunto de `paths` que as regras do espelho negam (mesma mecânica do deny_match do hetzner-mirror.sh: `git check-ignore --no-index` num repo temporário, regras como excludesFile).
    Falha em qualquer passo ou canário errado = Unreadable."""
    root = tempfile.mkdtemp(prefix="wa-node-classify.")
    try:
        deny = os.path.join(root, "deny")
        # falhou ao gravar -> Unreadable (nunca "nada negado")
        try:
            with open(deny, "w", encoding="utf-8") as fh:
                fh.write("\n".join(rules) + "\n")
        except OSError:
            raise Unreadable("espelho-nao-gravou")
        # dentro de um hook o git exporta GIT_DIR etc.: sem limpar, o `git init`/`check-ignore` agiriam em outro repositório
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        repo = os.path.join(root, "r")
        # vazio (git sai 1 e não imprime nada = nenhum negado) -> só vale se os canários de dado forem negados, senão Unreadable; falhou/ilegível (git ausente, prazo, rc != 0/1) -> Unreadable
        probe = list(paths) + [CANARY_OK, CANARY_DOC] + list(CANARY_MIRROR_NO)
        try:
            i = subprocess.run([GIT, "init", "-q", repo], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, timeout=MIRROR_TIMEOUT)
            if i.returncode != 0:
                raise Unreadable("espelho-git-init-rc-%d" % i.returncode)
            r = subprocess.run([GIT, "-C", repo, "-c", "core.excludesFile=" + deny, "check-ignore", "--no-index", "-z", "--stdin"],
                               input=("\0".join(probe) + "\0").encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=MIRROR_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            raise Unreadable("espelho-git-sem-resposta")
        if r.returncode not in (0, 1):   # 0 = algum negado, 1 = nenhum; o resto é falha do git
            raise Unreadable("espelho-git-rc-%d" % r.returncode)
        denied = set(x for x in r.stdout.decode("utf-8", "replace").split("\0") if x)
        # canário: os de dado TÊM de ser negados e o de código/doc não; senão as regras ou o git não são o que eu penso
        if any(c not in denied for c in CANARY_MIRROR_NO) or CANARY_OK in denied or CANARY_DOC in denied:
            raise Unreadable("espelho-canario-errado")
        return denied
    finally:
        shutil.rmtree(root, ignore_errors=True)


def mirror_reach(cands):
    """(caminhos que chegam ao nó PELO ESPELHO, nota para `info`, caminhos que o ESPELHO RETEVE). `cands`: caminhos de texto (MIRROR_TEXT_EXT) que o rsync não lista. Chegam se (1) o filtro do rsync não os NEGA por regra
    (segredo, dado, pasta que nunca sai) e (2) o filtro do espelho, com a varredura de conteúdo, também não. Retidos = passam em (1) e o espelho nega em (2) (a varredura de conteúdo achou telefone/CPF neles,
    ex.: docs/data_dictionary.md, ga-t05a1z9): continuam sem ir ao nó; quem chama pode tratá-los como referência citada, nunca como algo que chegou. Qualquer leitura que falhe -> nenhum chega, NENHUM é retido
    + nota `espelho-ilegivel:<motivo>` (o mesmo resultado de antes desta regra: caminho fora do filtro -> mini; "não consegui ler" nunca vira "retido")."""
    if not cands:
        return [], [], []
    try:
        open_sent = sent_by_filter(cands, only_denies=True)
        ok = [p for p in cands if p in open_sent]
        if not ok:
            return [], [], []
        denied = mirror_denied(mirror_rules(), ok)
        return [p for p in ok if p not in denied], [], [p for p in ok if p in denied]
    except Unreadable as e:
        return [], ["espelho-ilegivel:" + str(e)], []


RESOLVE_EXT = CODE_EXT + ("html", "md")   # nome solto só é trocado se for código/texto; nome solto de dado (.db, .csv, .log, .json...) nunca: segue julgado como arquivo da raiz, que o filtro não manda


def resolve_loose(paths, sent):
    """(paths, sent, nota para `info`). Nome solto (sem pasta, ex. `map_viewer.html`, `job_timeout.sh`) é julgado como arquivo da RAIZ do repo, mas a bead quase sempre o usa de atalho para um arquivo
    de outra pasta (`templates/map_viewer.html`, `scripts/job_timeout.sh`): o falso "fora do filtro" e o código sem teste derivado (ga-2hd02v.3.17). Troca o nome solto pelo caminho real quando ele é inequívoco: (1) a própria bead cita UM caminho com pasta e esse
    nome E a árvore de REPO_REF, lida, não tem arquivo da raiz com ele (o solto podia ser esse, e aí o citado é outro arquivo), ou (2) a árvore tem UM arquivo com esse nome e nenhum na raiz. O caminho trocado passa pelo MESMO filtro, mac-only e espelho dos demais (nada é aberto por esta troca); só código/texto
    (RESOLVE_EXT) é trocado, nunca dado. vazio (nenhum candidato, ou mais de um) -> o nome segue solto, fora do filtro = mini, como antes; falhou/ilegível (árvore) -> idem + nota
    `caminho-solto-ilegivel:<motivo>`, nunca "resolvido" (nas DUAS regras: sem a árvore não dá para saber se o solto é o da raiz, e palpite não vira node).
    4º valor: os nomes soltos de código que NÃO existem em lugar nenhum da árvore lida (script de diagnóstico, `part.py`: ga-2hd02v.3.22), que a regra 7 não conta como "código citado". Só com a árvore
    lida e a bead sem citar o nome com pasta; árvore ilegível -> nenhum (sem ela não dá para saber se o nome é de um arquivo novo da raiz). `info` leva `caminho-solto-fora-da-arvore:<nome>`."""
    if not paths:
        return paths, sent, [], set()
    loose = [p for p in paths if "/" not in p and p.rsplit(".", 1)[-1].lower() in RESOLVE_EXT and (p not in sent or p.rsplit(".", 1)[-1].lower() in CODE_EXT)]   # texto/html que o filtro não manda, ou código solto (o filtro o deixa sair da raiz, mas sem o caminho real a regra 6 não acha o teste dele)
    if not loose:
        return paths, sent, [], set()
    foldered = [p for p in paths if "/" in p]
    tree, tried, ok, note, swap, ghosts = set(), False, False, [], {}, set()
    for p in loose:
        if not tried:
            tried = True
            try:
                tree, ok = set(repo_tree()), True
            except Unreadable as e:
                note = ["caminho-solto-ilegivel:" + str(e)]
        cited = sorted(set(q for q in foldered if q.rsplit("/", 1)[-1] == p))
        if cited:
            if len(cited) == 1 and ok and p not in tree:   # dois citados com o mesmo nome: não sei qual é; árvore ilegível ou com o nome na raiz: o solto pode ser o da raiz. Em ambos fica solto
                swap[p] = cited[0]
            continue
        hits = sorted(f for f in tree if f.rsplit("/", 1)[-1] == p)
        if len(hits) == 1 and hits[0] != p and all(SAFE_SEG.match(sg) for sg in hits[0].split("/")):   # hits == [p]: o arquivo é o da raiz mesmo, nada a trocar
            swap[p] = hits[0]
        elif ok and not hits and p.rsplit(".", 1)[-1].lower() in CODE_EXT:   # nenhum arquivo com esse nome em lugar nenhum (nem na raiz): não é código do repo, é script de diagnóstico ou arquivo novo
            ghosts.add(p)
    note += ["caminho-solto-fora-da-arvore:" + p for p in sorted(ghosts)]
    if not swap:
        return paths, sent, note, ghosts
    out = []
    for p in paths:
        q = swap.get(p, p)
        if q not in out:
            out.append(q)
    new = sorted(set(q for q in swap.values() if q not in sent))
    if new:
        sent = set(sent) | sent_by_filter(new)
    return out, sent, note + ["caminho-solto:%s=%s" % (p, q) for p, q in swap.items()], ghosts


def mac_only_globs():
    # ausente/ilegível -> Unreadable (sem a lista não sei o que tem de ficar no Mac); existe mas sem NENHUM glob (truncada? só comentários?) -> Unreadable também: a lista real nunca é vazia,
    # e "não sei" não pode ler como "nada é só-Mac"
    try:
        with open(MAC_ONLY, "r", encoding="utf-8") as fh:
            globs = [l.strip() for l in fh if l.strip() and not l.lstrip().startswith("#")]
    except OSError:
        raise Unreadable("mac-only-ilegivel")
    if not globs:
        raise Unreadable("mac-only-vazio")
    return globs


def has_pii(blob):
    """True se o texto tem telefone/CPF com a forma do hetzner-pii-scan.py (cauda sintética não conta, como lá). Vazio -> False."""
    for m in PH.finditer(blob):
        d = re.sub(r"\D", "", m.group(0))
        if len(set(d[-8:])) > 3:
            return True
    return CPF.search(blob) is not None


def repo_git_env():
    # dentro de um hook o git exporta GIT_DIR etc.: sem limpar, os comandos agiriam em outro repositório; pathspec literal: nome de teste com [ ou * não vira glob
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_LITERAL_PATHSPECS"] = "1"
    return env


_TREE = []   # cache de uma execução da árvore de REPO_REF (lista com 0 ou 1 item)


def repo_tree():
    """caminhos dos arquivos de REPO_REF no repo do WA (o que o espelho entrega ao nó). Ref de formato estranho, git ausente ou sem resposta no prazo, rc != 0 (repo ou ref inexistente) e árvore VAZIA
    (a real nunca é vazia) -> Unreadable: nunca "o repo não tem testes"."""
    if _TREE:   # só uma leitura que DEU CERTO fica guardada (as moles, a âncora e as regras 6-8 pedem a mesma árvore); falha sobe de novo, nunca vira "árvore vazia"
        return _TREE[0]
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./\-]*", REPO_REF):
        raise Unreadable("repo-ref-invalida")
    try:
        r = subprocess.run([GIT, "-C", REPO_DIR, "ls-tree", "-r", "-z", "--name-only", REPO_REF], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=repo_git_env(), timeout=REPO_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable("repo-git-sem-resposta")
    if r.returncode != 0:
        raise Unreadable("repo-git-rc-%d" % r.returncode)
    files = [x for x in r.stdout.decode("utf-8", "replace").split("\0") if x]
    if not files:
        raise Unreadable("repo-vazio")
    _TREE.append(files)
    return files


def file_stem(path):
    """nome do arquivo sem a última extensão (`lib/foo_bar.py` -> `foo_bar`; `x.test.js` -> `x.test`)."""
    base = path.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[0] if "." in base else base


def valid_stem(s):
    """`s` se serve para achar teste/código por nome (no formato, longo o bastante, nada genérico), senão ""."""
    return s if STEM_RE.match(s) and len(s) >= MIN_STEM and s not in GENERIC_STEMS else ""


def module_stem(path):
    """o nome de módulo de um arquivo de código citado, ou "" se não serve para achar teste por nome (fora do formato, curto demais, genérico demais)."""
    return valid_stem(file_stem(path))


def grep_cites(stem, tests):
    """subconjunto de `tests` (arquivos de REPO_REF) cujo CONTEÚDO tem `stem` como palavra inteira. git grep sai 1 quando nenhum casa -> vazio (legítimo); rc 0 sem nome algum que eu leia, git ausente,
    prazo ou rc > 1 -> Unreadable: nunca "nenhum cita"."""
    try:
        r = subprocess.run([GIT, "-C", REPO_DIR, "grep", "-l", "-w", "-F", "-z", "-e", stem, REPO_REF, "--"] + list(tests), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=repo_git_env(), timeout=REPO_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable("repo-grep-sem-resposta")
    if r.returncode not in (0, 1):
        raise Unreadable("repo-grep-rc-%d" % r.returncode)
    pre = REPO_REF + ":"   # com um tree-ish o git imprime `<ref>:<caminho>`
    hits = set(x[len(pre):] for x in r.stdout.decode("utf-8", "replace").split("\0") if x.startswith(pre))
    if r.returncode == 0 and not hits:
        raise Unreadable("repo-grep-ilegivel")
    return hits


def derived_tests(code, globs):
    """{arquivo de código citado: [testes que o repo do WA já tem para ele]} (regra 6). Entram só testes que (1) são de um código que existe em REPO_REF, (2) têm no NOME o módulo (test_<módulo>.ext ou
    test_<módulo>_*.ext) sem serem de um módulo de nome mais longo que também existe, (3) têm no CONTEÚDO o módulo como palavra inteira, e (4) o nó TEM: filtro do rsync, lista mac-only e espelho com a
    varredura de conteúdo. Nada achado -> {} (vazio é um estado legítimo); qualquer leitura que falhe -> Unreadable (quem chama devolve unknown com a nota; nunca node)."""
    tree = repo_tree()
    present = set(tree)
    stems_all, test_rest = set(), []   # nomes de módulo (fora de tests/) e, de cada teste, o que vem depois de `test_`
    for f in tree:
        base = f.rsplit("/", 1)[-1]
        if f.startswith("tests/"):
            m = TEST_FILE_RE.match(base)
            if m:
                test_rest.append((f, m.group(1)))
        elif base.rsplit(".", 1)[-1] in DERIVE_EXT:
            stems_all.add(file_stem(f))
    cand = {}
    for p in code:
        s = module_stem(p) if p in present and p.rsplit(".", 1)[-1] in DERIVE_EXT else ""   # código que não existe em REPO_REF (arquivo novo, caminho solto) ou que não é de DERIVE_EXT (.css) não ganha teste por nome
        if not s:
            continue
        # `test_bar_service_extra_x` é de `bar_service_extra`, não de `bar_service`: se existe módulo mais longo que começa com o nome e o teste começa com o nome dele, o teste é dele
        longer = [m for m in stems_all if m.startswith(s + "_")]
        mine = sorted(f for f, rest in test_rest
                      if (rest == s or rest.startswith(s + "_")) and not any(rest == m or rest.startswith(m + "_") for m in longer))
        if mine:
            cand[p] = (s, mine[:MAX_DERIVED_PER_STEM])
    # regra 6b (ga-qkc02kk): código SEM teste de nome ganha os testes que o IMPORTAM (import estático que resolve para o mesmo arquivo). vazio -> nenhum; leitura que falha sobe como Unreadable
    imp = {}
    for p in code:
        s = module_stem(p) if p in present and p.rsplit(".", 1)[-1] in DERIVE_EXT else ""
        if s and p not in cand and (p.endswith(".py") or p.rsplit(".", 1)[-1] in JS_TEST_EXT):
            its = importer_tests(p, s, present)
            if its:
                imp[p] = (s, its)
    if not cand and not imp:
        return {}
    allc = sorted(set(t for _, ts in list(cand.values()) + list(imp.values()) for t in ts))[:MAX_DERIVED_TESTS]
    sent = sent_by_filter(allc)
    keep = [t for t in allc if t in sent and not any(fnmatch.fnmatchcase(t, g) for g in globs)]
    if keep:
        denied = mirror_denied(mirror_rules(), keep)
        keep = [t for t in keep if t not in denied]
    keep = set(keep)
    found = {}
    for p, (s, ts) in cand.items():
        ts = [t for t in ts if t in keep]
        if not ts:
            continue
        hits = grep_cites(s, ts)
        ok = [t for t in ts if t in hits]
        if ok:
            found[p] = ok
    for p, (s, ts) in imp.items():   # o import já provou que o teste usa o módulo (o grep -w só achou o candidato): passa só pelos filtros do nó
        ok = [t for t in ts if t in keep]
        if ok:
            found[p] = ok
            for t in ok:
                TEST_VIA[(p, t)] = "importador"
    return found


def derivable_code(f):
    """arquivo de código (DERIVE_EXT) que não é teste e tem nome seguro: o que a regra 7 pode propor como "o código da bead"."""
    return f.rsplit(".", 1)[-1] in DERIVE_EXT and not TEST_RE.search(f) and all(SAFE_SEG.match(x) for x in f.split("/"))


def name_tokens(text):
    """nomes de módulo que o texto cita SEM caminho (snake_case ou com hífen -> snake_case), na ordem em que aparecem e sem repetir. Só os que valem como nome (valid_stem); o que é caminho
    (dir/arq.ext, ~/x, o prefixo do repo) sai antes, porque já foi lido pela regra 3."""
    flat = PATH_RE.sub(" ", HOME_RE.sub(" ", text.replace(REPO_ABS, "")))
    out = []
    for m in NAME_RE.finditer(flat):
        s = valid_stem(m.group(1).lower().replace("-", "_"))
        if s and s not in out:
            out.append(s)
            if len(out) >= MAX_NAME_TOKENS:
                break
    return out


def parent_of(b):
    """id do pai da bead (o que os commits das irmãs citam): o campo `parent` do `bd show --json` ou, sem ele, o id sem o último `.N`. "" quando não há pai ou o id não tem a forma de id de bead."""
    p = b.get("parent")
    if isinstance(p, str) and PARENT_RE.match(p):
        return p
    i = b.get("id")
    if isinstance(i, str) and "." in i:
        p = i.rsplit(".", 1)[0]
        if PARENT_RE.match(p):
            return p
    return ""


def cache_file(parent):
    return os.path.join(CACHE_DIR, "sib-" + hashlib.sha1(parent.encode("utf-8")).hexdigest()[:20] + ".json")


def cache_get(parent):
    """arquivos guardados para o pai, ou None. Sem cache, vencido, de outro pai ou ilegível -> None e a quem chama recalcula: o cache só poupa tempo, nunca decide nada (e o conteúdo dele ainda passa
    pela árvore e pelos filtros como se tivesse acabado de sair do git)."""
    try:
        with open(cache_file(parent), encoding="utf-8") as fh:
            d = json.load(fh)
        age = time.time() - float(d["ts"])
        if d["parent"] == parent and -60 <= age <= SIBLING_TTL and isinstance(d["files"], list) and all(isinstance(x, str) for x in d["files"]):
            return d["files"]
    except Exception:
        pass
    return None


def cache_put(parent, files):
    """grava (escrita atômica) e apaga o que passou de 2 TTL. True se gravou; qualquer falha de disco -> False e segue sem cache (o resultado já está na mão)."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        path = cache_file(parent)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"parent": parent, "ts": time.time(), "files": files}, fh)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        now = time.time()
        for n in os.listdir(CACHE_DIR):
            q = os.path.join(CACHE_DIR, n)
            if n.startswith("sib-") and n.endswith(".json") and now - os.path.getmtime(q) > 2 * SIBLING_TTL:
                os.unlink(q)
        return True
    except Exception:
        return False


def sibling_log(parent):
    """arquivos de código tocados pelos commits de REPO_REF (dos últimos SIBLING_DAYS dias) que citam `<pai>.N` (as irmãs da bead e ela mesma). Do cache quando há; senão `git log --grep` limitado em dias, commits e tempo. Nenhum commit -> []
    (legítimo, e vai ao cache); git ausente, sem resposta no prazo ou rc != 0 -> Unreadable e NADA vai ao cache: nunca "as irmãs não tocaram em nada"."""
    hit = cache_get(parent)
    if hit is not None:
        COST["cache"] = "hit"
        return hit
    pat = "(^|[^A-Za-z0-9.-])" + parent.replace(".", "\\.") + "\\.[0-9]+([^0-9.]|$)"
    try:
        r = subprocess.run([GIT, "-C", REPO_DIR, "log", REPO_REF, "--since=%d.days.ago" % SIBLING_DAYS, "-E", "--grep=" + pat, "--name-only", "--format=", "-z", "-n", str(SIBLING_MAX_COMMITS), "--"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=repo_git_env(), timeout=SIBLING_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable("irmas-git-sem-resposta")
    if r.returncode != 0:
        raise Unreadable("irmas-git-rc-%d" % r.returncode)
    names = sorted(set(x.strip("\n") for x in r.stdout.decode("utf-8", "replace").split("\0")))
    names = [x for x in names if x and derivable_code(x)][:SIBLING_MAX_NAMES]
    COST["cache"] = "miss" if cache_put(parent, names) else "nao-gravou"
    return names


def in_backup_dir(f):
    """True se alguma PASTA do caminho (o nome do arquivo não conta) tem uma palavra de cópia (BACKUP_WORDS): `lib.bak-20260313-200326/x.py`, `archive/x.py`. Só olha o caminho; quem chama ignora a cópia
    apenas quando existe o homônimo vivo, então uma pasta viva com nome de cópia perde a escolha para o outro homônimo mas nunca faz uma bead virar node sozinha."""
    return any(t in BACKUP_WORDS for seg in f.split("/")[:-1] for t in re.split(r"[._\-0-9]+", seg.lower()) if t)


def derive_code(b, text):
    """({arquivo de código: origem}, notas) que a bead NOMEIA sem citar o caminho (regra 7): (a) nome snake_case/hífen do texto = nome de arquivo de código em REPO_REF (até MAX_FILES_PER_NAME; mais que isso
    é ambíguo e não deriva); (b) arquivos de código que os commits das irmãs (mesmo pai) tocaram e que ainda existem em REPO_REF. Cópia de backup (in_backup_dir) com homônimo vivo (mesmo nome de arquivo
    fora de pasta de cópia) é ignorada nas duas fontes, e a ambiguidade de (a) conta só os vivos (ga-2hd02v.3.22: `lib.bak-*/followup_manager.py` freava `lib/followup_manager.py` como "fora do filtro"); só há
    cópia -> o comportamento antigo (derivar a cópia, e o filtro a freia). Mais de MAX_DERIVED_CODE no total -> nada. Sem nome nem pai o repo nem é lido ({}, []); repo/git ilegível -> Unreadable (quem
    chama devolve unknown com a nota, nunca node)."""
    names, parent = name_tokens(text), parent_of(b)
    if not names and not parent:
        return {}, []
    tree = repo_tree()
    present = set(tree)
    by_stem, notes, out, live_stems = {}, [], {}, set()
    for f in tree:
        if derivable_code(f):
            by_stem.setdefault(file_stem(f), []).append(f)
            if not in_backup_dir(f):
                live_stems.add(file_stem(f))
    ignored = 0
    for n in names:
        fs = sorted(by_stem.get(n, []))
        if n in live_stems:
            ignored += sum(1 for f in fs if in_backup_dir(f))
            fs = [f for f in fs if not in_backup_dir(f)]
        if len(fs) > MAX_FILES_PER_NAME:
            notes.append("caminho-derivado-ambiguo:%s=%d" % (n, len(fs)))
            continue
        for f in fs:
            out.setdefault(f, "nome:" + n)
    if parent:
        for f in sibling_log(parent):
            if f in present:
                if in_backup_dir(f) and file_stem(f) in live_stems:
                    ignored += 1
                    continue
                out.setdefault(f, "irmas")
    if ignored:
        notes.append("caminho-derivado-backup-ignorado:%d" % ignored)
    if len(out) > MAX_DERIVED_CODE:
        return {}, notes + ["caminho-derivado-demais:%d" % len(out)]
    return out, notes


def judged_derived(found, tag, paths, tests, info, dinfo):
    """o veredito de uma prova DERIVADA (regras 6, 7 e 8): node `<tag>:N-teste(s)+M-codigo(s)`; mas envio no texto (DERIVED_BLOCK_INFO) manda ao mini, porque é uma prova mais fraca que o teste citado."""
    blocked = [s for s in DERIVED_BLOCK_INFO if s in info]
    if blocked:
        return "mini", ["freio-derivado:" + ",".join(blocked)], paths, tests, info + dinfo
    for c in found:                                                 # os arquivos de código e de teste desta prova são onde as moles procuram evidência (regra 4); código só das irmãs é palpite: lido, mas só informa
        (PROOF_SOFT if DERIVED_SRC.get(c) == "irmas" else PROOF).add(c)
    PROOF.update(t for ts in found.values() for t in ts)
    ntests = len(set(t for ts in found.values() for t in ts))
    return "node", ["%s:%d-teste(s)+%d-codigo(s)" % (tag, ntests, len(found))], paths, tests, info + dinfo


def path_derivation(b, text, paths, tests, info, extra):
    """regra 7 (ga-2hd02v.3.20): a bead não cita código; o código que ela nomeia (derive_code) passa pelos MESMOS filtros do citado (rsync, mac-only) e ganha prova. Devolve a tupla do classify, ou None
    (nada derivado, ou derivado sem teste: segue unknown). `extra` recebe o que vai em `info`. Fora do filtro/só no Mac -> mini; leitura que falha sobe como Unreadable."""
    dcode, notes = derive_code(b, text)
    extra += notes
    if not dcode:
        return None
    dpaths = sorted(dcode)
    DERIVED_SRC.update(dcode)
    cpairs = ["caminho-derivado:%s=%s" % (dcode[p], p) for p in dpaths]
    extra += cpairs[:6] + (["caminho-derivado-mais:%d" % (len(cpairs) - 6)] if len(cpairs) > 6 else [])
    dsent = sent_by_filter(dpaths)
    globs = mac_only_globs()
    hard = []
    for p in dpaths:
        if p not in dsent:
            hard.append("caminho-derivado-fora-do-filtro:" + p)
        elif any(fnmatch.fnmatchcase(p, g) for g in globs):
            hard.append("caminho-derivado-so-no-mac:" + p)
    if hard:
        return "mini", sorted(set(hard)), paths, tests, info + extra
    if tests:   # a bead cita o teste e nomeia o código: a mesma prova da regra 5, só que o caminho do código veio do repo
        found = dict((p, list(tests)) for p in dpaths)
    else:
        found = derived_tests(dpaths, globs)
        pairs = ["%s:%s=%s" % ("teste-importador" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in dpaths for t in found.get(c, [])]
        extra += pairs[:6] + (["teste-derivado-mais:%d" % (len(pairs) - 6)] if len(pairs) > 6 else [])
    if not found:
        return None
    return judged_derived(found, "prova-caminho-derivado", paths, tests, info, extra)


def repo_show(path, what="teste"):
    """texto de `path` em REPO_REF (`git show`; nunca a árvore de trabalho). git ausente ou sem resposta no prazo, rc != 0 (o caminho já foi visto na árvore, então não existir é falha) ou arquivo grande demais
    -> Unreadable: nunca "o teste está vazio". Um arquivo de 0 bytes lido com sucesso é texto vazio e é legítimo."""
    # vazio → texto "" (0 bytes lidos com sucesso: o teste não importa nada); falhou/ilegível → Unreadable (git ausente, prazo, rc != 0, arquivo grande), nunca "teste vazio"
    try:
        r = subprocess.run([GIT, "-C", REPO_DIR, "show", REPO_REF + ":" + path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=repo_git_env(), timeout=REPO_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable(what + "-git-sem-resposta")
    if r.returncode != 0:
        raise Unreadable("%s-git-rc-%d" % (what, r.returncode))
    if len(r.stdout) > MAX_TEST_BYTES:
        raise Unreadable(what + "-grande")
    return r.stdout.decode("utf-8", "replace")


def py_imports(src):
    """[(nível, módulo, nomes)] de todo `import`/`from … import` do código Python `src`, em qualquer ponto do arquivo (import dentro de função também conta). Só `ast.parse`: nada é executado.
    Texto que não parseia -> Unreadable (não sei o que ele importa); sem nenhum import -> [] (legítimo)."""
    # vazio → [] (arquivo sem import é legítimo); falhou/ilegível → Unreadable("teste-nao-parseia"), nunca []
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")   # `\d` em string comum vira SyntaxWarning no stderr; não muda o que se lê
            tree = ast.parse(src)
    except (SyntaxError, ValueError, RecursionError, MemoryError):
        raise Unreadable("teste-nao-parseia")
    out = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            out += [(0, a.name, []) for a in n.names]
        elif isinstance(n, ast.ImportFrom):
            out.append((n.level or 0, n.module or "", [a.name for a in n.names if a.name != "*"]))
    return out


def py_candidates(test, level, module, names):
    """arquivos de REPO_REF que um `import`/`from` do `test` pode estar nomeando (ainda sem saber se existem): `a/b.py` e `a/b/__init__.py` por raiz; em `from a import c`, `c` também pode ser submódulo (`a/c.py`).
    Relativo (`level` > 0) parte da pasta do teste; absoluto procura em IMPORT_ROOTS e na pasta do teste e na de cima. Nome que não casa arquivo do repo (stdlib, terceiro) simplesmente não existe na árvore."""
    parts = [x for x in module.split(".") if x]
    mods = ([parts] if parts else []) + [parts + [n] for n in names]
    tdir = posixpath.dirname(test)
    if level:
        base = tdir
        for _ in range(level - 1):
            base = posixpath.dirname(base)
        roots = [base]
    else:
        roots = list(dict.fromkeys(list(IMPORT_ROOTS) + [tdir, posixpath.dirname(tdir)]))
    out = []
    for r in roots:
        for m in mods:
            stem = posixpath.join(r, *m)
            out += [stem + ".py", stem + "/__init__.py"]
    return out


def js_candidates(test, spec):
    """arquivos de REPO_REF que `require('<spec>')`/`import … from '<spec>'` do `test` pode estar nomeando. Só caminho relativo (`./`, `../`) é do repo; pacote npm e builtin (`fs`, `node:path`) não; relativo que sai do repo também não."""
    if not spec.startswith(("./", "../")):
        return []
    base = posixpath.normpath(posixpath.join(posixpath.dirname(test), spec))
    if base == ".." or base.startswith("../"):
        return []
    exts = ("js", "cjs", "mjs", "ts")
    return [base] + [base + "." + e for e in exts] + [base + "/index." + e for e in exts]


def imported_code(tests):
    """({arquivo de código: [testes citados que o importam]}, [testes citados que não li]) (regra 8). Só entra arquivo que EXISTE em REPO_REF e é código (derivable_code: py/sh/js/mjs/cjs/ts, fora de tests/). Teste citado
    que não está em REPO_REF (novo nesta bead) ou de extensão que não sei ler (.sh...) não tem o que ler: não entra no dicionário e vai na segunda lista (a regra o nomeia em `info`, para a contagem não parecer completa);
    nada importado do repo -> {} (vazio é um estado legítimo). repo, git show ou parse que falha -> Unreadable."""
    present = set(repo_tree())
    found, unread = {}, []
    for t in sorted(set(tests)):
        ext = t.rsplit(".", 1)[-1]
        if t not in present or not (ext == "py" or ext in JS_TEST_EXT):
            unread.append(t)
            continue
        # vazio → este teste não importa nada do repo (segue para o próximo); falhou/ilegível → Unreadable sobe e a regra devolve unknown com a nota, nunca "sem import"
        src = repo_show(t)
        if ext == "py":
            cands = [c for lvl, mod, names in py_imports(src) for c in py_candidates(t, lvl, mod, names)]
        else:
            cands = [c for m in JS_IMPORT_RE.finditer(strip_js_comments(src)) for c in js_candidates(t, m.group(2))]
        for c in cands:
            if c in present and derivable_code(c) and t not in found.setdefault(c, []):
                found[c].append(t)
    return {c: ts for c, ts in found.items() if ts}, unread


def import_derivation(tests, paths, info, extra):
    """regra 8 (ga-2hd02v.3.21): a bead cita teste e nenhum código; o código que o teste IMPORTA (imported_code) passa pelos MESMOS filtros do citado (rsync, mac-only). Devolve a tupla do classify, ou None (nada
    importado do repo, ou mais de MAX_DERIVED_CODE: segue unknown). `extra` recebe o que vai em `info`. Fora do filtro/só no Mac -> mini; leitura que falha sobe como Unreadable."""
    found, unread = imported_code(tests)
    if not found:
        return None
    dpaths = sorted(found)
    if len(dpaths) > MAX_DERIVED_CODE:
        extra.append("codigo-do-teste-demais:%d" % len(dpaths))
        return None
    pairs = ["codigo-do-teste:%s=%s" % (t, c) for c in dpaths for t in found[c]]
    extra += pairs[:6] + (["codigo-do-teste-mais:%d" % (len(pairs) - 6)] if len(pairs) > 6 else [])
    # vazio (todo teste citado foi lido) -> nenhuma nota; o que não foi lido (teste novo, .sh...) não conta no N-teste(s) do motivo e é nomeado aqui (até 3, depois `-mais`), para a prova não parecer cobrir a lista inteira
    extra += ["teste-nao-lido:" + t for t in unread[:3]] + (["teste-nao-lido-mais:%d" % (len(unread) - 3)] if len(unread) > 3 else [])
    # vazio (o filtro não deixa sair nenhum dos arquivos) → todos entram em `hard` e a bead vai ao mini; falhou/ilegível (filtro, rsync, canário, lista mac-only ausente ou sem glob) → Unreadable sobe (unknown com a nota), nunca "todos passam"
    dsent = sent_by_filter(dpaths)
    globs = mac_only_globs()
    hard = []
    for p in dpaths:
        if p not in dsent:
            hard.append("codigo-do-teste-fora-do-filtro:" + p)   # o teste importa o módulo e o nó não o recebe: rodaria vermelho
        elif any(fnmatch.fnmatchcase(p, g) for g in globs):
            hard.append("codigo-do-teste-so-no-mac:" + p)
    if hard:
        return "mini", sorted(set(hard)), paths, tests, info + extra
    return judged_derived(found, "prova-codigo-derivado-do-teste", paths, tests, info, extra)


def exec_base(t):
    """o nome do executável de UMA string de Python usada como argv[0]: a própria string (sem "/"), ou o basename quando ela tem cara de caminho de executável (`/Users/x/.local/bin/secret`, `~/bin/bw`, `$HOME/…`,
    `_/secret` de um f-string, `…/bin/…`). Com espaço (linha de shell, o CRED_SHELL_RE/HOST_SHELL_RE cuidam) ou caminho comum (`lib/security`: módulo, não o binário do Mac) -> "" (não é argv[0])."""
    # vazio (string vazia, com espaço, caminho que não parece executável) -> ""; nunca levanta
    if not t or any(c.isspace() for c in t):
        return ""
    if "/" not in t:
        return t
    if t.startswith(("/", "~", "$", "_/", "bin/")) or "/bin/" in t:
        return t.rsplit("/", 1)[-1]
    return ""


def py_exec_parts(src):
    """(strings, calls, modules) do código EXECUTÁVEL de `src` (Python), sem docstring e sem comentário, por `ast.parse` (nada é executado). Não parseia -> None: quem chama cai no texto (mais largo)."""
    # vazio (arquivo sem string nem chamada) -> três listas vazias, legítimo; falhou/ilegível (SyntaxError, ValueError, RecursionError, MemoryError) -> None, NUNCA listas vazias
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(src)
    except (SyntaxError, ValueError, RecursionError, MemoryError):
        return None
    docs = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and n.body:
            f = n.body[0]
            if isinstance(f, ast.Expr) and isinstance(f.value, ast.Constant) and isinstance(f.value.value, str):
                docs.add(id(f.value))
    pieces = {id(v) for n in ast.walk(tree) if isinstance(n, ast.JoinedStr) for v in n.values if isinstance(v, ast.Constant)}   # pedaços de f-string: entram remontados (abaixo), não um a um
    strs, calls, mods = [], [], []
    for n in ast.walk(tree):
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docs and id(n) not in pieces:
            strs.append(n.value[:MAX_STR_LEN])
        elif isinstance(n, ast.JoinedStr):   # f"shared/data/{nome}.db", f"secret {chave}": o ast parte em pedaços; remonta com `_` no lugar de cada {…} (o pedaço dinâmico é palavra, como o regex espera)
            strs.append("".join(v.value if isinstance(v, ast.Constant) and isinstance(v.value, str) else "_" for v in n.values)[:MAX_STR_LEN])
        elif isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if nm:
                calls.append(nm)
        elif isinstance(n, ast.Import):
            mods += [a.name for a in n.names]
        elif isinstance(n, ast.ImportFrom):
            mods += [n.module or ""] + [(n.module or "") + "." + a.name for a in n.names]
    return strs, calls, mods


def strip_js_comments(src):
    """o JS/TS sem comentário (`/* … */` e `// …` até o fim da linha, menos o `//` de URL): `// const m = require('../lib/x.js')` não é import. Tira A MAIS que o comentário só quando há `//` dentro de string na mesma linha
    (o import depois dele some -> "ninguém importa" -> unknown, o lado conservador). Um require escrito DENTRO de string continua contando (limite conhecido, runbook)."""
    return re.sub(r"/\*.*?\*/|(?<![:\\])//[^\n]*", "", src, flags=re.S)


def strip_comment_lines(text):
    """o texto sem as linhas que SÓ têm comentário (#, //, *, /*): serve para sh/js e para Python que não parseia. Não tira comentário no fim da linha (mais largo, na dúvida acha mais evidência)."""
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith(("#", "//", "*", "/*")))


def scan_evidence(path, text, is_test):
    """{slug: [o que achou]} das moles que o CÓDIGO de `path` mostra (regra 4, ga-qkc02kk). Só o que a lista do Mayor nomeia: (credencial) o cofre em QUALQUER forma do WA — argv exato ou com caminho do binário, linha de shell/f-string ("secret x"), wrapper do repo (secret_bin(), lib.secret_cli),
    chamada `secret`/`bw`, módulo do cofre —, arquivo de credencial (.env, credentials*.json, token.json...); (banco-de-dados) caminho de banco de PRODUÇÃO — `shared/data/x.db`, `md:`, `~/`/`/Users/…/x.db` e, só fora de teste, nome de banco solto (`"queue.db"`: o WA monta o caminho por
    pedaços); (host-mac) osascript/launchctl/Chrome do Mac/adb, também como CHAMADA (connect_over_cdp(...)) e em linha de shell. O ramo `ast` (Python que parseia) tem de achar o MESMO que o ramo de texto (.sh/.js): um idioma que só o texto vê vira "li e não achei" no caso comum. Variável de ambiente com nome de token, `sqlite3.connect(variavel)` e `/Users/…` sozinho NÃO são evidência: o teste os substitui, ou é só caminho-padrão.
    Vazio -> {}. Python que não parseia -> o texto sem linhas de comentário (mais largo). Nunca lê o disco: `text` é o que o `git show` devolveu."""
    out = {}

    def hit(slug, what):
        out.setdefault(slug, [])
        if what not in out[slug]:
            out[slug].append(what[:48])

    parts = py_exec_parts(text) if path.endswith(".py") else None
    if parts is not None:
        strs, calls, mods = parts
        for c in calls:
            if CRED_CALL_RE.match(c):
                hit("credencial", c + "()")
            if HOST_CALL_RE.search(c):
                hit("host-mac", c + "()")
        for m in mods:
            if CRED_MOD_RE.search(m):
                hit("credencial", "import " + m)
            if any(HOST_CALL_RE.search(x) for x in m.split(".")):
                hit("host-mac", "import " + m)
        for t in strs:
            b = exec_base(t)
            if b in CRED_CLI:
                hit("credencial", "argv:" + b)
            elif CRED_FILE_RE.search(t):
                hit("credencial", CRED_FILE_RE.search(t).group(0).strip("/\\"))
            else:
                m = CRED_SHELL_RE.search(t)
                if m:
                    hit("credencial", "sh:" + m.group(0).strip(" ;|&(`"))
            if b in HOST_ARGV:
                hit("host-mac", "argv:" + b)
            else:
                m = HOST_RE.search(t) or HOST_SHELL_RE.search(t)
                if m:
                    hit("host-mac", m.group(0).strip(" ;|&(`"))
            m = DB_PINNED_RE.search(t) or (None if is_test else DB_BARE_RE.search(t))
            if m:
                hit("banco-de-dados", m.group(0))
        return out
    blob = strip_comment_lines(text)
    for rx, slug in ((CRED_TEXT_RE, "credencial"), (HOST_RE, "host-mac"), (DB_PINNED_RE, "banco-de-dados")):
        m = rx.search(blob)
        if m:
            hit(slug, m.group(0).strip())
    if not is_test and "banco-de-dados" not in out:
        m = DB_BARE_RE.search(blob)
        if m:
            hit("banco-de-dados", m.group(0))
    return out


def mole_gate(proof, prose, soft_files=()):
    """(motivos duros, info) das moles de uma bead que JÁ tem prova de código+teste (regra 4, ga-qkc02kk). As moles procuram EVIDÊNCIA no código dos arquivos de prova (citados e derivados), lidos em REPO_REF; a palavra
    escrita na bead (`prose`) só informa quando a leitura deu certo. TRÊS ESTADOS: (1) leu e achou evidência -> `moles:<slug>` (mini), mesmo sem palavra; (2) leu e NÃO achou -> sem motivo, a palavra vai em `info`
    (`mole-so-em-prosa:<slug>`); (3) NÃO consegui ler (git, arquivo grande demais) ou não havia arquivo nenhum que existisse em REPO_REF (tudo novo) -> volta a regra antiga, a palavra bloqueia
    (`moles:<slug>` das palavras), e `info` diz por quê (`mole-ilegivel:<motivo>`, sempre, mesmo sem palavra; `mole-sem-arquivo-lido` quando tudo é novo e há palavra). "Não li" nunca vira "li e não achei". Arquivo NOVO (não está em REPO_REF) não tem o que ler: não soma evidência e não bloqueia, desde que ao menos UM arquivo
    existente tenha sido lido (o nó só precisa construir e testar o arquivo novo contra fixtures; o que ele faria em produção é do mini, depois do merge)."""
    files = sorted(f for f in proof if f.rsplit(".", 1)[-1] in SCAN_EXT)
    fallback = ["moles:" + s for s in prose]
    evsoft, softbad = {}, []
    # vazio (nenhum arquivo de prova com extensão lida) -> sem base para dizer "não achei": volta a palavra; falhou/ilegível (árvore, git show, arquivo grande) -> volta a palavra + nota, nunca "sem evidência"
    try:
        tree = set(repo_tree())
        ev, novos, nread = {}, [], 0
        for f in files:
            if f not in tree:
                novos.append(f)
                continue
            text = repo_show(f, "arquivo")
            nread += 1
            for slug, whats in scan_evidence(f, text, bool(TEST_RE.search(f))).items():
                ev.setdefault(slug, []).extend((f, w) for w in whats)
        for f in sorted(x for x in soft_files if x not in proof and x in tree and x.rsplit(".", 1)[-1] in SCAN_EXT):   # palpite das irmãs: lê, mas a evidência só informa
            # vazio (sem evidência) -> nada a informar; falhou/ilegível (git, arquivo grande) -> SÓ a nota `mole-irma-ilegivel`: um palpite que informa não pode, ao falhar, virar a palavra que barra
            try:
                soft_text = repo_show(f, "arquivo")
            except Unreadable as e:
                softbad.append("mole-irma-ilegivel:" + str(e))
                continue
            for slug, whats in scan_evidence(f, soft_text, bool(TEST_RE.search(f))).items():
                evsoft.setdefault(slug, []).extend((f, w) for w in whats)
    except Unreadable as e:
        return fallback, ["mole-ilegivel:" + str(e)]   # `-ilegivel` é o que o Pilot soma em `leitura` (a leitura que FALHOU): sai MESMO sem palavra, porque "não consegui varrer" não pode parecer "varri e não achei"
    if nread == 0:
        return fallback, (["mole-sem-arquivo-lido"] if prose else [])
    hard = ["moles:" + s for s in MOLE_SLUGS if s in ev]
    pairs = ["mole-evidencia:%s=%s[%s]" % (s, f, w) for s in MOLE_SLUGS for f, w in ev.get(s, [])]
    info = pairs[:MOLE_INFO_MAX] + (["mole-evidencia-mais:%d" % (len(pairs) - MOLE_INFO_MAX)] if len(pairs) > MOLE_INFO_MAX else [])
    info += ["mole-so-em-prosa:" + s for s in prose if s not in ev]
    soft_pairs = ["mole-evidencia-irma:%s=%s[%s]" % (s, f, w) for s in MOLE_SLUGS for f, w in evsoft.get(s, [])]
    info += soft_pairs[:MOLE_INFO_MAX] + (["mole-evidencia-irma-mais:%d" % (len(soft_pairs) - MOLE_INFO_MAX)] if len(soft_pairs) > MOLE_INFO_MAX else [])
    info += softbad[:MOLE_INFO_MAX]
    if novos and (prose or ev or evsoft):   # só quando a regra das moles teve o que decidir; sem palavra e sem evidência o arquivo novo não muda nada e a resposta fica como era
        info.append("mole-arquivo-novo:%d" % len(novos))
    return hard, info


MAX_IMPORTER_SCAN = 60   # testes que citam o módulo e são lidos para ver se IMPORTAM (ordem alfabética); acima disso o excesso nem é lido (menos prova, nunca prova errada)


def importer_tests(code, stem, present):
    """testes de `tests/` em REPO_REF que IMPORTAM `code` (regra 6b, ga-qkc02kk): a prova de "teste vizinho" para código sem teste de nome. O `git grep -w <módulo>` só acha candidatos; quem prova é o `import` estático
    (Python por `ast`, JS por require/import relativo sem os comentários) que resolve para O MESMO arquivo — citar o nome numa string ou comentário não conta (em JS, um require DENTRO de string conta). Vazio (grep rc 1, ou nenhum candidato resolve) -> []; git/grep/leitura do
    candidato que falha -> Unreadable (sobe: nunca "ninguém importa"); candidato que não parseia é PULADO e contado em NOTES (a regra só afirma o que provou)."""
    try:
        r = subprocess.run([GIT, "-C", REPO_DIR, "grep", "-l", "-w", "-F", "-z", "-e", stem, REPO_REF, "--", "tests"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=repo_git_env(), timeout=REPO_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Unreadable("repo-grep-sem-resposta")
    if r.returncode not in (0, 1):
        raise Unreadable("repo-grep-rc-%d" % r.returncode)
    pre = REPO_REF + ":"
    hits = sorted(x[len(pre):] for x in r.stdout.decode("utf-8", "replace").split("\0") if x.startswith(pre))
    if r.returncode == 0 and not hits:
        raise Unreadable("repo-grep-ilegivel")
    cand_all = [t for t in hits if t in present and (t.rsplit(".", 1)[-1] == "py" or t.rsplit(".", 1)[-1] in JS_TEST_EXT)]
    cand = cand_all[:MAX_IMPORTER_SCAN]
    if len(cand_all) > len(cand):   # o excesso nem é lido: um importador depois do 60º candidato some como "ninguém importa" (unknown, conservador) — agora avisa em vez de ficar invisível
        NOTES.append("teste-importador-truncado:%d" % (len(cand_all) - len(cand)))
    out, skipped = [], 0
    for t in cand:
        src = repo_show(t)   # falhou/ilegível -> Unreadable sobe (a regra devolve unknown com a nota)
        try:
            if t.endswith(".py"):
                cands = [c for lvl, mod, names in py_imports(src) for c in py_candidates(t, lvl, mod, names)]
            else:
                cands = [c for m in JS_IMPORT_RE.finditer(strip_js_comments(src)) for c in js_candidates(t, m.group(2))]
        except Unreadable:
            skipped += 1
            continue
        if code in cands:
            out.append(t)
    if skipped:
        NOTES.append("teste-importador-nao-parseou:%d" % skipped)
    return out[:MAX_DERIVED_PER_STEM]


def anchor_code(b, text):
    """({código derivado: origem}, notas) para a bead que só cita DADO (ga-qkc02kk): o código que ela nomeia sem caminho ou que as irmãs tocaram (derive_code, a mesma derivação da regra 7: nomes e irmãs) serve de âncora para o dado citado virar
    evidência — sem âncora a bead só tem dado e nada a construir. O código ancorado passa pelos MESMOS filtros do citado (rsync, mac-only); um que o nó não recebe -> sem âncora e o dado segue duro. Nada derivado ->
    ({}, notas); leitura que falha (repo, git, cache, rsync, mac-only) -> Unreadable sobe e quem chama deixa o dado duro, com nota."""
    dcode, notes = derive_code(b, text)
    if not dcode:
        return {}, notes
    dpaths = sorted(dcode)
    dsent = sent_by_filter(dpaths)
    globs = mac_only_globs()
    if any(p not in dsent or any(fnmatch.fnmatchcase(p, g) for g in globs) for p in dpaths):
        return {}, notes + ["ancora-derivada-fora-do-no"]
    return dcode, notes


def classify_core(b):
    """(veredito, motivos, caminhos, testes, info) SEM o portão das moles (regra 4): `classify` o aplica ao `node` que sair daqui. Deixa em PROSE as moles escritas na bead e em PROOF os arquivos da prova."""
    labels = labels_of(b)
    text = bead_text(b)
    ntext = norm(text.replace(REPO_ABS, ""))   # o prefixo absoluto do repo não é dependência de host (o caminho em si é julgado por extract_paths); outro /Users/... continua mole
    info =[slug for slug, rx in INFO_RE if rx.search(ntext)]
    if "node:mini" in labels:
        return "mini", ["etiqueta-node:mini"], [], [], info
    # `exec:manual` = um HUMANO executa à mão (criar chave em console, aparelho físico): um construtor do nó nunca faz isso. O Pilot já não roteia essas beads, mas a palavra mole ("chave", "secret") era o que as
    # segurava aqui por acaso (wa-zmxywv.35.3.4: «Athos: criar a chave da API da Anthropic» virou `node` quando a palavra deixou de barrar). A trava passa a ser explícita e não depende de vocabulário.
    if "exec:manual" in labels:
        return "mini", ["etiqueta-exec:manual"], [], [], info
    if b.get("issue_type") == "epic":
        return "mini", ["epic"], [], [], info
    paths, hard, odd = extract_paths(text)
    # o texto inteiro da bead (todos os campos, metadata incluída) vai ao nó: dado de lead nele é duro. json.dumps do que o json.loads leu não falha
    if has_pii(json.dumps(b, ensure_ascii=False)):
        hard.append("dado-no-texto")
    sent = sent_by_filter(paths) if paths else None
    paths, sent, loose_note, ghosts = resolve_loose(paths, sent)   # nome solto -> o caminho real, quando é inequívoco (julgado pelo mesmo filtro); ghosts = soltos que não existem na árvore
    globs = mac_only_globs() if paths else []
    # texto neutro que o rsync não lista mas o espelho entrega (docs/, DESIGN.md...): só os .md fora da lista pagam a consulta ao espelho; os demais caminhos seguem como antes.
    # vazio (nenhum .md fora da lista) -> o espelho nem é consultado; falhou/ilegível -> nenhum chega e `info` leva espelho-ilegivel:<motivo> (o caminho segue 'fora do filtro' = mini, como antes desta regra)
    via_mirror, note, withheld = mirror_reach([p for p in paths if p not in sent and p.rsplit(".", 1)[-1].lower() in MIRROR_TEXT_EXT]) if paths else ([], [], [])
    info += loose_note + note + ["via-espelho:" + p for p in via_mirror]
    code, tests, blocked = [], [], []
    for p in paths:
        if p not in sent and p not in via_mirror:
            blocked.append(("caminho-fora-do-filtro:" + p, p, p))   # duro, a não ser que seja evidência de dado (decidido abaixo, quando já se sabe se a bead cita código)
        elif any(fnmatch.fnmatchcase(p, g) for g in globs):
            hard.append("so-no-mac:" + p)
        elif p in via_mirror:
            pass  # texto que o espelho entrega não é prova de nada, nem de código nem de teste: 'docs/tests/plan.md' casa TEST_RE mas não é teste (o rsync só manda /tests/ da raiz)
        elif TEST_RE.search(p):
            tests.append(p)
        elif p.rsplit(".", 1)[-1] in CODE_EXT:
            code.append(p)
        # senão: o filtro deixa sair (ex.: /templates/x.html, /CLAUDE.md) e o nó o tem, mas não é código nem teste: nem bloqueia nem conta como prova
    # evidência ≠ dependência (ga-t05a1z9): o que o filtro ou o formato seguraram é motivo duro, EXCETO caminho de dado/log (ou doc que o espelho reteve) quando a bead cita >=1 arquivo de CÓDIGO que o filtro deixa
    # passar (nome solto que não existe na árvore, `ghosts`, não é código). Vira `info` (evidencia-de-dado:/evidencia-de-doc:), nunca vai ao nó: o filtro e o espelho seguem segurando o dado.
    # vazio (nada segurado, ou bead sem código citado) -> nenhuma evidência: o que foi segurado continua duro, como antes; falhou (espelho ilegível: `withheld` vem vazio + nota `espelho-ilegivel`) -> o doc continua
    # duro, "não consegui ler" nunca vira "retido" nem evidência. Nome com cara de segredo (secretish) e código/.plist/.sql/.env fora do filtro nunca são evidência.
    blocked += [("caminho-fora-do-formato", o, o) for o in odd]
    has_code = any(c not in ghosts for c in code)
    # ÂNCORA DERIVADA (ga-qkc02kk, b): a bead só cita DADO/LOG que o nó não recebe (9 das 43 P0/P1 do WA, medido na ga-t05a1z9 em 01/11) e nenhum código. O código que ela nomeia sem caminho ou que as irmãs tocaram (anchor_code, mesma
    # derivação da regra 7, pelos mesmos filtros) faz o papel do "código citado": o dado vira evidência, e a prova (teste) ainda é exigida adiante. Só tenta quando TUDO que está segurado seria evidência e não há outra
    # razão dura (telefone/CPF, só-no-Mac, caminhos demais). vazio (nada derivado) -> o dado segue duro; falhou/ilegível (repo, git, rsync, mac-only) -> o dado segue duro + nota `ancora-derivada-ilegivel`, nunca âncora.
    if not has_code and blocked and not hard and all(("doc" if p in withheld and not secretish(p) else evidence_kind(p)) for _, p, _ in blocked):
        try:
            anc, anotes = anchor_code(b, text)
        except Unreadable as e:
            anc, anotes = {}, ["ancora-derivada-ilegivel:" + str(e)]
        info += anotes
        if anc:
            has_code = True
            info.append("evidencia-ancorada-em-derivado:%d" % len(anc))
    evid = []
    for why_hard, p, tok in blocked:
        kind = "doc" if p in withheld and not secretish(p) else evidence_kind(p)
        if has_code and kind:
            evid.append((kind, p, tok))
        else:
            hard.append(why_hard)
    names = ["evidencia-de-%s:%s" % (k, p) for k, p, _ in evid]
    info += names[:MAX_EVIDENCE_INFO] + (["evidencia-de-dado-mais:%d" % (len(names) - MAX_EVIDENCE_INFO)] if len(names) > MAX_EVIDENCE_INFO else [])
    if hard:
        return "mini", sorted(set(hard)), paths, tests, info
    # a palavra mole não pode vir do próprio caminho de evidência: `queue.db` casa `\.db\b` (banco) e `/Users/athos/shared/data/x.db` casa `/users/` (host Mac) só por estarem CITADOS como prova. Tira os tokens
    # de evidência do texto das moles; "banco", "sqlite", "token"... escritos em prosa continuam valendo, e o `ntext` das INFORMATIVAS não muda.
    # do MAIS LONGO ao mais curto: o nome solto `x.db` está dentro do absoluto `/Users/.../x.db`; tirando o curto primeiro o longo deixa de casar e sobra `/users/` (host Mac) do próprio caminho de evidência
    soft_text = ntext
    for tok in sorted(set(norm(t.replace(REPO_ABS, "")) for _, _, t in evid), key=len, reverse=True):
        soft_text = soft_text.replace(tok, " ")
    soft = [slug for slug, rx in SOFT_RE if rx.search(soft_text)]
    PROSE[:] = soft   # a palavra mole é PROSA (ga-qkc02kk): quem decide é a evidência no código da prova, aplicada por `classify` ao `node` que sair daqui (mole_gate)
    override = "node:ok" in labels
    why = ["moles-ignoradas:" + ",".join(soft)] if soft else []
    if override:
        return "node", why + ["etiqueta-node:ok"], paths, tests, info
    PROOF.update(code)    # o que a bead cita é o que as moles leem (um nome solto que não existe na árvore cai em "arquivo novo" no portão)
    PROOF.update(tests)
    if tests and code:
        return "node", ["prova-no-texto:%d-teste(s)+%d-codigo" % (len(tests), len(code))], paths, tests, info
    # regra 6: código citado e nenhum teste citado -> o teste que o repo já tem para esse código.
    # vazio (nenhum teste do módulo) -> segue unknown como antes, sem nota; falhou/ilegível (repo, git, rsync, espelho) -> unknown + nota `teste-derivado-ilegivel`, nunca node e nunca "vazio"
    found, note = {}, []
    if code and not tests:
        try:
            found = derived_tests(code, globs)
        except Unreadable as e:
            note = ["teste-derivado-ilegivel:" + str(e)]
    if found:
        pairs = ["%s:%s=%s" % ("teste-importador" if TEST_VIA.get((c, t)) else "teste-derivado", c, t) for c in code for t in found.get(c, [])]
        dinfo = pairs[:6] + (["teste-derivado-mais:%d" % (len(pairs) - 6)] if len(pairs) > 6 else [])
        return judged_derived(found, "prova-teste-derivado", paths, tests, info, dinfo)
    # regra 7: NENHUM código citado -> o código que a bead nomeia sem caminho (módulo/tela/daemon) ou que as irmãs tocaram, pelos mesmos filtros do citado.
    # vazio (nada nomeado, nada na árvore, derivado sem teste) -> segue unknown, SEM nota; falhou/ilegível (repo, git, cache de irmãs, rsync, mac-only, espelho) -> unknown + nota `caminho-derivado-ilegivel`, nunca node e nunca "vazio"
    # regra 8 (ga-2hd02v.3.21): teste citado, nenhum código, e a regra 7 LEU e não derivou nada -> o código que o teste importa. vazio (o teste não importa nada do repo) -> segue unknown, SEM nota;
    # falhou/ilegível (repo, git show, teste que não parseia, rsync, mac-only) -> unknown + nota `codigo-do-teste-ilegivel`, nunca node e nunca "vazio"
    # a regra 7 que NÃO CONSEGUIU LER (r7_failed) não é "a regra 7 não derivou nada": o git log das irmãs pode ter o código que a regra 8 não veria (e o freio dele) -> a regra 8 NÃO roda, fica unknown + `caminho-derivado-ilegivel`
    extra = []
    if not [c for c in code if c not in ghosts]:   # nome solto que não existe na árvore (`part.py`) segue em `code` para a regra 5, mas não impede a 7 de achar o código que a bead nomeia
        t0 = time.monotonic()
        r7_failed = False
        try:
            res = path_derivation(b, text, paths, tests, info, extra)
        except Unreadable as e:
            res = None
            r7_failed = True
            extra.append("caminho-derivado-ilegivel:" + str(e))
        if res is None and tests and not r7_failed:
            try:
                res = import_derivation(tests, paths, info, extra)
            except Unreadable as e:
                res = None
                extra.append("codigo-do-teste-ilegivel:" + str(e))
        COST["derivacao_ms"] = int((time.monotonic() - t0) * 1000)
        if res:
            return res
    return "unknown", ["sem-prova-de-codigo-e-teste"], paths, tests, info + note + extra


def classify(b):
    """(veredito, motivos, caminhos, testes, info). As moles (regra 4) são o ÚLTIMO portão: classify_core acha a prova; se o veredito é `node` (menos por `node:ok`, que é decisão humana e ignora as moles), o
    mole_gate lê o código dos arquivos de prova e só `moles:<slug>` com EVIDÊNCIA manda ao mini. Sem prova nenhuma o veredito segue `unknown` (antes uma palavra mole o fazia `mini`) e as palavras vão em
    `info` como `palavra-mole:<slug>`. PII, freio de envio, caminho duro e `node:mini` são decididos antes e não mudam."""
    PROOF.clear()
    PROOF_SOFT.clear()
    DERIVED_SRC.clear()
    del PROSE[:]
    del NOTES[:]
    TEST_VIA.clear()
    v, why, paths, tests, info = classify_core(b)
    if v == "node" and "etiqueta-node:ok" not in why:
        hard, notes = mole_gate(PROOF, list(PROSE), PROOF_SOFT)
        if hard:
            return "mini", hard, paths, tests, info + NOTES + notes
        info = info + notes
    elif v == "unknown" and PROSE:
        info = info + ["palavra-mole:" + s for s in PROSE]
    return v, why, paths, tests, info + NOTES


def main(argv):
    if len(argv) > 1:
        sys.stderr.write("uso: wa-node-classify.py < bead.json   (o JSON do `bd show <id> --json`)\n")
        return EX_USAGE
    # stdin vazio ou ilegível -> unknown (via Unreadable em load_bead); acima do teto -> unknown
    t0 = time.monotonic()
    raw = sys.stdin.buffer.read(MAX_IN + 1)
    try:
        if len(raw) > MAX_IN:
            raise Unreadable("entrada-grande")
        v, why, paths, tests, info = classify(load_bead(raw.decode("utf-8", "replace")))
    except Unreadable as e:
        v, why, paths, tests, info = "unknown", ["nao-consegui:" + str(e)], [], [], []
    except Exception as e:   # o que eu não previ (JSON aninhado demais, disco cheio no mkdtemp...) também é "não consegui": nunca um crash que o chamador leia como outra coisa
        v, why, paths, tests, info = "unknown", ["erro-inesperado:" + type(e).__name__], [], [], []
    # basis: de onde veio o `node` — a etiqueta de um humano, a prova no texto ou o teste que o repo já tem (o Pilot liga uma e a outra em degraus: modo label, depois auto);
    # só o node tem basis, e o `derivado` é separado do `text` porque é uma prova mais fraca (ver LIMITES)
    if "etiqueta-node:ok" in why:
        basis = "label"
    elif v == "node":
        basis = "derivado" if any(w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:", "prova-codigo-derivado-do-teste:")) for w in why) else "text"
    else:
        basis = ""
    # custo: ms da execução inteira e da regra 7 (0 se ela não rodou) + o estado do cache das irmãs; vem ANTES de info (quem lê o fim da linha continua achando `"info": [...]}`)
    custo = {"ms": int((time.monotonic() - t0) * 1000), "derivacao_ms": COST["derivacao_ms"], "cache": COST["cache"]}
    print(json.dumps({"verdict": v, "basis": basis, "reasons": why, "paths": paths, "tests": tests, "custo": custo, "info": info}, ensure_ascii=False))
    return {"node": EX_NODE, "mini": EX_MINI}.get(v, EX_UNKNOWN)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
