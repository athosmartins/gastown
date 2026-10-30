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
  2. etiqueta `node:mini` (decisão humana) ou tipo epic                                           -> mini
  3. DURAS (nem `node:ok` vence): (a) todo caminho de ARQUIVO citado na bead (forma dir/arq.ext, extensão da lista PATH_RE, maiúscula ou minúscula) passa pelo filtro REAL do rsync (um
     `rsync -n` sobre uma árvore temporária com os caminhos citados + 3 canários; canário errado = unknown) e pela lista mac-only, porque o nó simplesmente não tem o arquivo; caminho
     absoluto, `..`, `~/...`, `$VAR/...` ou fora do formato; mais de 40 caminhos; EXCEÇÃO (ga-2hd02v.3): um `.md` que o rsync não lista (docs/, DESIGN.md...) chega ao nó pelo ESPELHO git, que
     entrega tudo menos o que a varredura de CONTEÚDO sinalizou; então ele deixa de ser "fora do filtro" se (i) o filtro do rsync não o NEGA por regra (segredo, dado, pasta que nunca sai:
     shared/, logs/...) e (ii) o filtro que o espelho serve (`hetzner-mirror.sh spec-out`, só com a varredura em dia) também não o nega. Espelho ilegível, em atualização ou com canário errado
     = volta à regra acima (mini) e `info` leva `espelho-ilegivel:<motivo>`; json/txt/yaml... nunca ganham a exceção (é onde mora dado com nome neutro). O `.md` entregue vai em `info` como
     `via-espelho:<caminho>`; ele não conta como prova (nem código nem teste); (b) a bead (todos os campos, metadata
     incluída) tem telefone ou CPF com a forma do hetzner-pii-scan.py, porque o TEXTO da bead viaja ao nó e dado de lead não pode ir junto                               -> mini
  4. MOLES (palavras que dizem "toca recurso vivo": banco real, credencial, host Mac): `node:ok` (decisão humana) as ignora e o motivo `moles-ignoradas` fica na resposta; sem
     `node:ok`                                                                                      -> mini
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
     (`info`: teste-derivado:<código>=<teste>); mas se o texto tem palavra informativa de dado de lead ou de envio de WhatsApp (os freios de DERIVED_BLOCK_INFO) -> mini, `freio-derivado:<palavras>`.
     Não achou -> unknown. Repo/git/espelho ilegível -> unknown com `info` `teste-derivado-ilegivel:<motivo>`; nunca vira node.
  7. CAMINHO DERIVADO (ga-2hd02v.3.20; só quando a bead NÃO cita nenhum arquivo de código; medido 30/10: 13 de 30 beads sondadas caíam em unknown `sem-prova-de-codigo-e-teste` porque o texto NOMEIA o módulo mas
     não escreve o caminho): o caminho sai do próprio repo do WA em origin/main, nunca de palpite. (a) NOMES: palavra com `_` ou `-` no texto (ficha_donos, form-fill; maiúscula vale; até 30 por bead) que é o nome
     de arquivo de código (sem a extensão, >=5 letras, nada genérico) na árvore do repo; um nome com mais de 3 arquivos é ambíguo (`info`: caminho-derivado-ambiguo:<nome>=N) e não deriva nada; palavra colada a
     `/` ou a uma extensão é caminho, não nome. (b) IRMÃS: os arquivos de código tocados pelos commits `fix|feat(<id>)` das beads de MESMO PAI (o campo `parent` ou o id sem o último `.N`; até 40 commits dos últimos 45 dias, WA_NODE_SIBLING_DAYS; um `git log`
     com prazo próprio, WA_NODE_SIBLING_TIMEOUT, 15 s) que ainda existem na árvore. Mais de 10 arquivos derivados no total = nenhum (`caminho-derivado-demais:N`; é palpite largo). Os caminhos derivados passam pelos MESMOS
     filtros dos citados, sem afrouxar nada: filtro do rsync (fora dele -> mini `caminho-derivado-fora-do-filtro:<p>`), lista mac-only (mini `caminho-derivado-so-no-mac:<p>`), as moles e o PII da regra 3/4 (que já rodaram antes)
     e os freios de dado de lead/envio da regra 6 (mini `freio-derivado:…`). A prova do teste é a mesma da regra 6 (o teste que o repo já tem para o código derivado) ou, se a bead cita o teste, o próprio teste citado.
     Achou -> node, basis `derivado`, motivo `prova-caminho-derivado:N-teste(s)+M-codigo(s)` (`info`: caminho-derivado:<nome:X|irmas>=<caminho>, teste-derivado:<código>=<teste>). Nada derivado ou nenhum teste -> unknown como antes.
     Falha de leitura (repo, git, rsync, mac-only, espelho, git log das irmãs sem resposta) -> unknown com `info` `caminho-derivado-ilegivel:<motivo>`; "falhou" nunca é "vazio" e nunca é node. Custo: os `git ls-tree`/`git log` só
     rodam com nome ou pai para consultar; o `git log` das irmãs fica num cache por pai (6 h; o cache nunca decide: o conteúdo dele passa pela árvore e pelos filtros, e cache ilegível/vencido/de outro pai é recalculado);
     o JSON leva `custo` ({ms, derivacao_ms, cache}) e o Pilot o grava na linha da sonda. NÃO há LLM nem `recall` por sonda: o recall de beads fechadas parecidas levou >120 s numa consulta sob load 80 (medido), então a
     fonte "3 beads parecidas" do pedido original NÃO foi implementada. O cache por (id, updated_at) do veredito já existe no dispatcher (memo da passada do nó); o cache daqui é só o do `git log` das irmãs.

CÓDIGOS DE SAÍDA: 0 node · 10 mini · 11 unknown · 2 uso. A linha de stdout é um JSON: {"verdict","basis","reasons":[...],"paths":[...],"tests":[...],"custo":{"ms","derivacao_ms","cache"},"info":[...]}; basis = label | text | derivado | "" (só o node tem).
O QUE NÃO FAZ: não lê dado, não abre o nó, não toca o Dolt, não escreve na bead. Lê só stdin (o JSON do `bd show --json`), o filtro, a lista mac-only, (só com `.md` fora do rsync) o filtro que o espelho serve e (só com código citado sem teste citado) a árvore e o conteúdo dos TESTES do repo do WA em origin/main, por `git ls-tree`/`git grep`: nunca a árvore de trabalho; (só sem código citado, regra 7) a árvore de código do repo e o `git log` dos commits das beads irmãs. ESCREVE uma única coisa: o cache do `git log` das irmãs (WA_NODE_CACHE, padrão <cidade>/.gc/cache/wa-node-classify; escrita atômica, opcional: sem ele o classificador só fica mais lento).
LIMITES: a exceção do espelho confia na varredura de conteúdo (>=20 telefones ou >=3 CPFs distintos por arquivo): lista pequena, nome, e-mail e CNPJ num `.md` passam; vale o mesmo resíduo do bloco 3b do filtro. É heurística de TEXTO sobre a bead; o texto pode omitir que o teste abre um banco. NÃO são extraídos: pasta sem arquivo (`data/`), arquivo sem nome (`.env`), extensão fora da lista, nome com
  sufixo (`x.py.bak` não vira `x.py`). Para esses a regra 3a não age; quem segura o dado é o filtro do rsync (o nó nunca o recebe) e, no caso de `.env`/`.db`, a palavra mole da regra 4. O resíduo cai no nó como teste vermelho e a bead volta ao mini pelo gate (custo, não vazamento:
  o dado não chega ao nó de qualquer jeito). A lista de palavras moles é deliberadamente larga (o vocabulário do WA é todo de lead/terreno): na dúvida a bead fica no mini, como hoje.
  A regra 6 prova que existe um teste do módulo que o cita; NÃO prova que ele cobre a mudança da bead, nem que roda sem recurso vivo (pode abrir banco, rede ou Chrome, ou dar skip e ficar verde sem provar nada): isso cai no nó como teste
  vermelho/skip e a bead volta ao mini pelo gate. Por isso o basis é `derivado` e não `text`: quem for ligar o modo auto pode tratar os dois de um jeito diferente. Plano, comentário e ctx-check NÃO entram: o plano (design/notes/acceptance_criteria)
  já é lido, o ctx-check só grava etiqueta e comentário de lacuna, e o worker do nó não recebe comentário (ga-2hd02v.10).
"""
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata

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
DERIVED_BLOCK_INFO = ("dado-de-lead", "envio-whatsapp")              # palavras informativas que, só para a prova derivada (mais fraca), mandam ao mini (lista do Mayor em ga-2hd02v.3.15); banco e credencial da mesma lista já são moles e bloqueiam antes
NAME_RE = re.compile(r"(?<![\w/.\-~$])([A-Za-z][A-Za-z0-9]*(?:[_\-][A-Za-z0-9]+)+)(?![\w/]|\.\w)")   # `ficha_donos`, `form-fill`: nome de módulo/tela/daemon SEM caminho (o que tem pasta ou extensão é caminho e já foi lido)
MAX_NAME_TOKENS = 30                                                 # nomes distintos lidos de uma bead
MAX_FILES_PER_NAME = 3                                               # um nome que casa mais arquivos que isto é ambíguo: não deriva nada dele
MAX_DERIVED_CODE = 10                                                # arquivos de código derivados no total; acima disso a bead não é sobre um módulo só: não deriva nada
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
    """(caminhos válidos em ordem, motivos duros). Caminho fora do formato seguro vira motivo duro: nunca vai ao disco."""
    seen, out, hard = set(), [], []
    if HOME_RE.search(text):
        hard.append("caminho-fora-do-formato")
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
            hard.append("caminho-fora-do-formato")
            continue
        if len(out) >= MAX_PATHS:   # o 41º caminho válido estoura o teto; exatamente 40 ainda vale
            hard.append("caminhos-demais")
            break
        out.append(p)
    return out, hard


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
    """(caminhos que chegam ao nó PELO ESPELHO, nota para `info`). `cands`: caminhos de texto (MIRROR_TEXT_EXT) que o rsync não lista. Chegam se (1) o filtro do rsync não os NEGA por regra
    (segredo, dado, pasta que nunca sai) e (2) o filtro do espelho, com a varredura de conteúdo, também não. Qualquer leitura que falhe -> nenhum chega + nota `espelho-ilegivel:<motivo>`
    (o mesmo resultado de antes desta regra: caminho fora do filtro -> mini)."""
    if not cands:
        return [], []
    try:
        open_sent = sent_by_filter(cands, only_denies=True)
        ok = [p for p in cands if p in open_sent]
        if not ok:
            return [], []
        denied = mirror_denied(mirror_rules(), ok)
        return [p for p in ok if p not in denied], []
    except Unreadable as e:
        return [], ["espelho-ilegivel:" + str(e)]


RESOLVE_EXT = CODE_EXT + ("html", "md")   # nome solto só é trocado se for código/texto; nome solto de dado (.db, .csv, .log, .json...) nunca: segue julgado como arquivo da raiz, que o filtro não manda


def resolve_loose(paths, sent):
    """(paths, sent, nota para `info`). Nome solto (sem pasta, ex. `map_viewer.html`, `job_timeout.sh`) é julgado como arquivo da RAIZ do repo, mas a bead quase sempre o usa de atalho para um arquivo
    de outra pasta (`templates/map_viewer.html`, `scripts/job_timeout.sh`): o falso "fora do filtro" e o código sem teste derivado (ga-2hd02v.3.17). Troca o nome solto pelo caminho real quando ele é inequívoco: (1) a própria bead cita UM caminho com pasta e esse
    nome E a árvore de REPO_REF, lida, não tem arquivo da raiz com ele (o solto podia ser esse, e aí o citado é outro arquivo), ou (2) a árvore tem UM arquivo com esse nome e nenhum na raiz. O caminho trocado passa pelo MESMO filtro, mac-only e espelho dos demais (nada é aberto por esta troca); só código/texto
    (RESOLVE_EXT) é trocado, nunca dado. vazio (nenhum candidato, ou mais de um) -> o nome segue solto, fora do filtro = mini, como antes; falhou/ilegível (árvore) -> idem + nota
    `caminho-solto-ilegivel:<motivo>`, nunca "resolvido" (nas DUAS regras: sem a árvore não dá para saber se o solto é o da raiz, e palpite não vira node)."""
    if not paths:
        return paths, sent, []
    loose = [p for p in paths if "/" not in p and p.rsplit(".", 1)[-1].lower() in RESOLVE_EXT and (p not in sent or p.rsplit(".", 1)[-1].lower() in CODE_EXT)]   # texto/html que o filtro não manda, ou código solto (o filtro o deixa sair da raiz, mas sem o caminho real a regra 6 não acha o teste dele)
    if not loose:
        return paths, sent, []
    foldered = [p for p in paths if "/" in p]
    tree, tried, ok, note, swap = set(), False, False, [], {}
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
    if not swap:
        return paths, sent, note
    out = []
    for p in paths:
        q = swap.get(p, p)
        if q not in out:
            out.append(q)
    new = sorted(set(q for q in swap.values() if q not in sent))
    if new:
        sent = set(sent) | sent_by_filter(new)
    return out, sent, note + ["caminho-solto:%s=%s" % (p, q) for p, q in swap.items()]


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


def repo_tree():
    """caminhos dos arquivos de REPO_REF no repo do WA (o que o espelho entrega ao nó). Ref de formato estranho, git ausente ou sem resposta no prazo, rc != 0 (repo ou ref inexistente) e árvore VAZIA
    (a real nunca é vazia) -> Unreadable: nunca "o repo não tem testes"."""
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
    if not cand:
        return {}
    allc = sorted(set(t for _, ts in cand.values() for t in ts))[:MAX_DERIVED_TESTS]
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


def derive_code(b, text):
    """({arquivo de código: origem}, notas) que a bead NOMEIA sem citar o caminho (regra 7): (a) nome snake_case/hífen do texto = nome de arquivo de código em REPO_REF (até MAX_FILES_PER_NAME; mais que isso
    é ambíguo e não deriva); (b) arquivos de código que os commits das irmãs (mesmo pai) tocaram e que ainda existem em REPO_REF. Mais de MAX_DERIVED_CODE no total -> nada. Sem nome nem pai o repo nem é
    lido ({}, []); repo/git ilegível -> Unreadable (quem chama devolve unknown com a nota, nunca node)."""
    names, parent = name_tokens(text), parent_of(b)
    if not names and not parent:
        return {}, []
    tree = repo_tree()
    present = set(tree)
    by_stem, notes, out = {}, [], {}
    for f in tree:
        if derivable_code(f):
            by_stem.setdefault(file_stem(f), []).append(f)
    for n in names:
        fs = sorted(by_stem.get(n, []))
        if len(fs) > MAX_FILES_PER_NAME:
            notes.append("caminho-derivado-ambiguo:%s=%d" % (n, len(fs)))
            continue
        for f in fs:
            out.setdefault(f, "nome:" + n)
    if parent:
        for f in sibling_log(parent):
            if f in present:
                out.setdefault(f, "irmas")
    if len(out) > MAX_DERIVED_CODE:
        return {}, notes + ["caminho-derivado-demais:%d" % len(out)]
    return out, notes


def judged_derived(found, tag, paths, tests, info, dinfo):
    """o veredito de uma prova DERIVADA (regras 6 e 7): node `<tag>:N-teste(s)+M-codigo(s)`; mas lead/envio no texto (DERIVED_BLOCK_INFO) mandam ao mini, porque é uma prova mais fraca que o teste citado."""
    blocked = [s for s in DERIVED_BLOCK_INFO if s in info]
    if blocked:
        return "mini", ["freio-derivado:" + ",".join(blocked)], paths, tests, info + dinfo
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
        pairs = ["teste-derivado:%s=%s" % (c, t) for c in dpaths for t in found.get(c, [])]
        extra += pairs[:6] + (["teste-derivado-mais:%d" % (len(pairs) - 6)] if len(pairs) > 6 else [])
    if not found:
        return None
    return judged_derived(found, "prova-caminho-derivado", paths, tests, info, extra)


def classify(b):
    """(veredito, motivos, caminhos, testes, info)."""
    labels = labels_of(b)
    text = bead_text(b)
    ntext = norm(text.replace(REPO_ABS, ""))   # o prefixo absoluto do repo não é dependência de host (o caminho em si é julgado por extract_paths); outro /Users/... continua mole
    info =[slug for slug, rx in INFO_RE if rx.search(ntext)]
    if "node:mini" in labels:
        return "mini", ["etiqueta-node:mini"], [], [], info
    if b.get("issue_type") == "epic":
        return "mini", ["epic"], [], [], info
    paths, hard = extract_paths(text)
    # o texto inteiro da bead (todos os campos, metadata incluída) vai ao nó: dado de lead nele é duro. json.dumps do que o json.loads leu não falha
    if has_pii(json.dumps(b, ensure_ascii=False)):
        hard.append("dado-no-texto")
    sent = sent_by_filter(paths) if paths else None
    paths, sent, loose_note = resolve_loose(paths, sent)   # nome solto -> o caminho real, quando é inequívoco (julgado pelo mesmo filtro)
    globs = mac_only_globs() if paths else []
    # texto neutro que o rsync não lista mas o espelho entrega (docs/, DESIGN.md...): só os .md fora da lista pagam a consulta ao espelho; os demais caminhos seguem como antes.
    # vazio (nenhum .md fora da lista) -> o espelho nem é consultado; falhou/ilegível -> nenhum chega e `info` leva espelho-ilegivel:<motivo> (o caminho segue 'fora do filtro' = mini, como antes desta regra)
    via_mirror, note = mirror_reach([p for p in paths if p not in sent and p.rsplit(".", 1)[-1].lower() in MIRROR_TEXT_EXT]) if paths else ([], [])
    info += loose_note + note + ["via-espelho:" + p for p in via_mirror]
    code, tests = [], []
    for p in paths:
        if p not in sent and p not in via_mirror:
            hard.append("caminho-fora-do-filtro:" + p)
        elif any(fnmatch.fnmatchcase(p, g) for g in globs):
            hard.append("so-no-mac:" + p)
        elif p in via_mirror:
            pass  # texto que o espelho entrega não é prova de nada, nem de código nem de teste: 'docs/tests/plan.md' casa TEST_RE mas não é teste (o rsync só manda /tests/ da raiz)
        elif TEST_RE.search(p):
            tests.append(p)
        elif p.rsplit(".", 1)[-1] in CODE_EXT:
            code.append(p)
        # senão: o filtro deixa sair (ex.: /templates/x.html, /CLAUDE.md) e o nó o tem, mas não é código nem teste: nem bloqueia nem conta como prova
    if hard:
        return "mini", sorted(set(hard)), paths, tests, info
    soft = [slug for slug, rx in SOFT_RE if rx.search(ntext)]
    override = "node:ok" in labels
    if soft and not override:
        return "mini", ["moles:" + s for s in soft], paths, tests, info
    why = ["moles-ignoradas:" + ",".join(soft)] if soft else []
    if override:
        return "node", why + ["etiqueta-node:ok"], paths, tests, info
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
        pairs = ["teste-derivado:%s=%s" % (c, t) for c in code for t in found.get(c, [])]
        dinfo = pairs[:6] + (["teste-derivado-mais:%d" % (len(pairs) - 6)] if len(pairs) > 6 else [])
        return judged_derived(found, "prova-teste-derivado", paths, tests, info, dinfo)
    # regra 7: NENHUM código citado -> o código que a bead nomeia sem caminho (módulo/tela/daemon) ou que as irmãs tocaram, pelos mesmos filtros do citado.
    # vazio (nada nomeado, nada na árvore, derivado sem teste) -> segue unknown, SEM nota; falhou/ilegível (repo, git, cache de irmãs, rsync, mac-only, espelho) -> unknown + nota `caminho-derivado-ilegivel`, nunca node e nunca "vazio"
    extra = []
    if not code:
        t0 = time.monotonic()
        try:
            res = path_derivation(b, text, paths, tests, info, extra)
        except Unreadable as e:
            res = None
            extra.append("caminho-derivado-ilegivel:" + str(e))
        COST["derivacao_ms"] = int((time.monotonic() - t0) * 1000)
        if res:
            return res
    return "unknown", ["sem-prova-de-codigo-e-teste"], paths, tests, info + note + extra


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
        basis = "derivado" if any(w.startswith(("prova-teste-derivado:", "prova-caminho-derivado:")) for w in why) else "text"
    else:
        basis = ""
    # custo: ms da execução inteira e da regra 7 (0 se ela não rodou) + o estado do cache das irmãs; vem ANTES de info (quem lê o fim da linha continua achando `"info": [...]}`)
    custo = {"ms": int((time.monotonic() - t0) * 1000), "derivacao_ms": COST["derivacao_ms"], "cache": COST["cache"]}
    print(json.dumps({"verdict": v, "basis": basis, "reasons": why, "paths": paths, "tests": tests, "custo": custo, "info": info}, ensure_ascii=False))
    return {"node": EX_NODE, "mini": EX_MINI}.get(v, EX_UNKNOWN)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
