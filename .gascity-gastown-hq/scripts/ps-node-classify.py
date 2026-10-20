#!/usr/bin/env python3
"""ps-node-classify.py — a bead do PS (property_scrapers) roda no nó Hetzner (código + testes, sem banco real, sem rede viva) ou só no mini? (ga-2hd02v.4)

Contents
  Regra · Três estados · Como decide · Diferenças para o wa-node-classify.py · Códigos de saída · O que NÃO faz · Limites

REGRA (Athos, 18/10): dado de lead/cliente não vai ao nó; (Athos, 20/10) o nó deve ficar 100% ocupado, quem ocupa não importa. Esta classificação decide ONDE a bead de PS roda; o que PODE chegar ao nó quem
  decide é o espelho git do rig + o filtro (hetzner-rsync-filter.ps.txt), e isso não muda aqui. Classificar errado custa uma bead que falha/trava no nó e volta ao mini; classificar certo é o que põe a CPU do nó para trabalhar.

TRÊS ESTADOS (sempre): node = li tudo e há prova de que é código + teste que o nó tem / mini = li e há prova de que precisa do mini / unknown = não consegui ler ou não há prova nenhuma.
  Só `node` manda a bead ao nó. `mini` e `unknown` rodam onde sempre rodaram: erro de leitura, filtro ilegível, rsync mudo ou canário errado caem em `unknown` (estado inerte), nunca em `node`.

COMO DECIDE (a 1ª regra que casa vale; tudo é lido da bead, nada é gravado nela):
  1. entrada que não é um objeto de bead (JSON ilegível, sem id/título, texto grande demais)      -> unknown
  2. etiqueta `node:mini` (decisão humana) ou tipo epic                                           -> mini
  3. DURAS (nem `node:ok` vence): (a) todo caminho de ARQUIVO citado na bead (forma dir/arq.ext) passa pelo filtro REAL do rsync (um `rsync -n` sobre uma árvore temporária com os caminhos citados + 3
     canários; canário errado = unknown) e pela lista mac-only (hetzner-mac-only.ps.txt), porque o nó simplesmente não tem o arquivo; caminho absoluto fora do repo, `..`, `~/...`, `$VAR/...` ou fora do formato; mais de 40
     caminhos; (b) a bead (todos os campos, metadata incluída) tem telefone ou CPF com a forma do hetzner-pii-scan.py, porque o TEXTO da bead viaja ao nó   -> mini
  4. MOLES (palavras que dizem "toca recurso vivo"): banco real (MotherDuck, duckdb, sqlite, parquet, ~/.property-scrapers), credencial (token, login, senha...), host Mac (launchd, plist, osascript, /Users/...) e
     REDE VIVA (proxy, IP residencial, Cloudflare, captcha, "ao vivo", "na rodada"): `node:ok` (decisão humana) as ignora e o motivo `moles-ignoradas` fica na resposta; sem `node:ok` -> mini
     INFORMATIVAS (produção, tela, dado de anúncio, ...) e o raspador citado que NÃO está liberado no nó (scripts/hetzner-scrape-eligible.txt): NÃO bloqueiam; vão para `info`, que o Pilot grava no jsonl da sombra
     para medir o acerto antes de ligar o modo `auto`.
  5. prova positiva: >=1 teste citado (caminho tests/ ou lib/tests/ ou test_*.py que o filtro deixa passar) E >=1 arquivo de código citado que o filtro deixa passar -> node, basis `text`;
     `node:ok` dispensa a prova (as duras já passaram) -> node, basis `label`; sem prova -> unknown

DIFERENÇAS PARA O wa-node-classify.py (cópia adaptada; as regras duras e os três estados são os mesmos): filtro e lista mac-only próprios do PS; o prefixo absoluto do repo e dos worktrees de crew
  (/Users/athos/gt/property_scrapers/[crew/<nome>/]) é normalizado; palavras moles de PS (rede viva, MotherDuck, launchd) no lugar das de WA (lead, terreno); variáveis de ambiente PS_NODE_*.

CÓDIGOS DE SAÍDA: 0 node · 10 mini · 11 unknown · 2 uso. A linha de stdout é um JSON: {"verdict","basis","reasons":[...],"paths":[...],"tests":[...],"info":[...]}.
O QUE NÃO FAZ: não lê dado, não abre o nó, não toca o Dolt, não escreve na bead. Lê só stdin (o JSON do `bd show --json`), o filtro, a lista mac-only e a lista de raspadores liberados.
LIMITES: é heurística de TEXTO sobre a bead; o texto pode omitir que o teste abre um banco ou a rede. NÃO são extraídos: pasta sem arquivo (`data/`), arquivo sem nome (`.env`), extensão fora da lista, nome com
  sufixo (`x.py.bak` não vira `x.py`). Para esses a regra 3a não age; quem segura o dado é o filtro do rsync/espelho (o nó nunca o recebe) e, no caso de `.env`/`.db`, a palavra mole da regra 4. O resíduo cai no nó como teste vermelho e a bead volta
  ao mini pelo gate (custo, não vazamento: o dado não chega ao nó de qualquer jeito). A lista de palavras moles é larga de propósito: na dúvida a bead fica no mini, como hoje.
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
FILTER = os.environ.get("PS_NODE_FILTER", os.path.join(HERE, "hetzner-rsync-filter.ps.txt"))
MAC_ONLY = os.environ.get("PS_NODE_MAC_ONLY", os.path.join(HERE, "hetzner-mac-only.ps.txt"))
ELIGIBLE = os.environ.get("PS_NODE_ELIGIBLE", os.path.join(HERE, "hetzner-scrape-eligible.txt"))
RSYNC = os.environ.get("PS_NODE_RSYNC", "rsync")
try:
    RSYNC_TIMEOUT = max(1, int(os.environ.get("PS_NODE_RSYNC_TIMEOUT", "30")))   # número ilegível -> 30 (o padrão), nunca um crash na importação
except ValueError:
    RSYNC_TIMEOUT = 30
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
REPO_ABS_RE = re.compile(r"/Users/athos/gt/property_scrapers/(?:crew/[\w.\-]+/)?")   # o repo e o worktree de uma crew/worker (as beads de PS citam os dois); outro /Users/... continua host Mac
CANARY_OK = "tests/test_zz_ps_node_canary.py"         # o filtro TEM de deixar sair
CANARY_NO = ("data/zz_ps_node_canary.json", ".env", "credentials_zz.json")   # o filtro TEM de segurar

# palavras do texto (sem acento, minúsculas). slug -> regex. Larga de propósito (ver LIMITES).
SOFT = (
    ("banco-de-dados", r"\b(sqlite3?|duckdb|motherduck|dolt|postgres\w*|mysql|bancos?|database|parquet|snapshots? (real|reais|de producao)|base de dados|base real|base viva)\b|\.db\b|\.property-scrapers|\bshared/"),
    ("credencial", r"\b(tokens?|secret\w*|senhas?|password|credencia\w*|api[_ -]?key|oauth|login|jwt|cookies?)\b|\.env\b"),
    ("host-mac", r"(/users/|\bosascript\b|\bhomebrew\b|\bbrew\b|\blaunchd\b|\blaunchctl\b|\bplists?\b|\bmbp\b|\bmac ?(mini|book)\b|\bkeychain\b)"),
    ("rede-viva", r"\b(proxy|proxies|residenciais?|residential|cloudflare|captcha|ao vivo|rodada real|na rodada|rodada diaria|rodada noturna|em producao)\b"),
)
# vocabulário do produto e da entrega: só informa (ver doc). Medir na sombra se alguma deveria passar a bloquear.
INFO = (
    ("producao", r"\b(producao|prod|deploy\w*|cron|crontab|backups?|s3|aws|drive|mount|rclone|restart\w*|reinici\w*|daemons?)\b"),
    ("raspagem", r"\b(raspad\w*|raspagem|scrap\w*|coleta\w*|rodada|tenants?|paginacao|retry|http ?[45][0-9][0-9]|429|403|503)\b"),
    ("dado-de-anuncio", r"\b(anuncios?|imoveis|imovel|lotes?|terrenos?|leiloes|leilao|csv|xlsx|cnpj|empreendimentos?|snapshots?|historico)\b"),
    ("tela-ao-vivo", r"\b(painel|dashboard|telas?|front-?end|navegador|playwright|screenshot|browser|chrome|html)\b"),
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
        p = REPO_ABS_RE.sub("", m.group(1), count=1) if m.group(1).startswith("/") else m.group(1)
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


def sent_by_filter(paths):
    """subconjunto de `paths` que o filtro REAL do rsync deixa sair. Falha em qualquer passo (filtro, rsync, canário) = Unreadable."""
    # filtro ausente/ilegível -> Unreadable (sem o filtro não sei o que o nó tem)
    try:
        with open(FILTER, "r", encoding="utf-8") as fh:
            if "- *" not in fh.read():
                raise Unreadable("filtro-sem-negacao-final")
    except OSError:
        raise Unreadable("filtro-ilegivel")
    root = tempfile.mkdtemp(prefix="ps-node-classify.")
    try:
        src, dst = os.path.join(root, "src"), os.path.join(root, "dst")
        os.mkdir(src)
        os.mkdir(dst)
        for p in list(paths) + [CANARY_OK] + list(CANARY_NO):
            full = os.path.join(src, p)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "w").close()
        # rsync -n lista o que SAIRIA; sem resposta/rc!=0/saída vazia -> Unreadable (nunca "nada sai" por engano)
        try:
            r = subprocess.run([RSYNC, "-a", "-n", "--out-format=%n", "--filter=. " + FILTER, src + "/", dst + "/"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=RSYNC_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            raise Unreadable("rsync-sem-resposta")
        if r.returncode != 0:
            raise Unreadable("rsync-rc-%d" % r.returncode)
        sent = set(l for l in r.stdout.decode("utf-8", "replace").splitlines() if l and not l.endswith("/"))
        # canário: o de código tem de sair e os de segredo/dado não; senão o filtro ou o rsync não é o que eu penso
        if CANARY_OK not in sent or any(c in sent for c in CANARY_NO):
            raise Unreadable("canario-errado")
        return sent
    finally:
        shutil.rmtree(root, ignore_errors=True)


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


def scraper_info(paths):
    """slugs `raspador-fora-do-no:<pasta>` para cada raspador citado (scrapers/<pasta>/...) que a lista de liberados NÃO libera no nó. SÓ INFORMA (a decisão nunca depende disto: editar o código de um raspador e
    testá-lo com fixture não precisa de rede). Lista ausente/ilegível -> `lista-de-raspadores-ilegivel` (não sei, e não digo que está liberado); sem raspador citado -> nada."""
    names = sorted(set(m.group(1) for p in paths for m in [re.match(r"scrapers/([^/]+)/", p)] if m))
    if not names:
        return []
    allowed, blocked = set(), set()
    # vazio (arquivo sem nenhum raspador liberado) -> todo raspador citado conta como fora do nó; falhou/ilegível -> `lista-de-raspadores-ilegivel` (só informa, a decisão não depende disto)
    try:
        with open(ELIGIBLE, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                neg = line.startswith("!")
                nm = line.lstrip("!").strip().lower()
                name, _, tenant = nm.partition(":")
                name, tenant = name.strip(), tenant.strip()
                if not re.fullmatch(r"[a-z0-9_\-]+", name):
                    continue
                if neg and not tenant:
                    blocked.add(name)
                elif not neg:
                    allowed.add(name)
    except (OSError, UnicodeError):
        return ["lista-de-raspadores-ilegivel"]
    return ["raspador-fora-do-no:" + n for n in names if n.lower() in blocked or n.lower() not in allowed]


def has_pii(blob):
    """True se o texto tem telefone/CPF com a forma do hetzner-pii-scan.py (cauda sintética não conta, como lá). Vazio -> False."""
    for m in PH.finditer(blob):
        d = re.sub(r"\D", "", m.group(0))
        if len(set(d[-8:])) > 3:
            return True
    return CPF.search(blob) is not None


def classify(b):
    """(veredito, motivos, caminhos, testes, info)."""
    labels = labels_of(b)
    text = bead_text(b)
    ntext = norm(REPO_ABS_RE.sub("", text))   # o prefixo absoluto do repo/worktree não é dependência de host (o caminho em si é julgado por extract_paths); outro /Users/... continua mole
    info =[slug for slug, rx in INFO_RE if rx.search(ntext)]
    if "node:mini" in labels:
        return "mini", ["etiqueta-node:mini"], [], [], info
    if b.get("issue_type") == "epic":
        return "mini", ["epic"], [], [], info
    paths, hard = extract_paths(text)
    info = info + scraper_info(paths)
    # o texto inteiro da bead (todos os campos, metadata incluída) vai ao nó: dado de lead nele é duro. json.dumps do que o json.loads leu não falha
    if has_pii(json.dumps(b, ensure_ascii=False)):
        hard.append("dado-no-texto")
    sent = sent_by_filter(paths) if paths else None
    globs = mac_only_globs() if paths else []
    code, tests = [], []
    for p in paths:
        if p not in sent:
            hard.append("caminho-fora-do-filtro:" + p)
        elif any(fnmatch.fnmatchcase(p, g) for g in globs):
            hard.append("so-no-mac:" + p)
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
    return "unknown", ["sem-prova-de-codigo-e-teste"], paths, tests, info


def main(argv):
    if len(argv) > 1:
        sys.stderr.write("uso: ps-node-classify.py < bead.json   (o JSON do `bd show <id> --json`)\n")
        return EX_USAGE
    # stdin vazio ou ilegível -> unknown (via Unreadable em load_bead); acima do teto -> unknown
    raw = sys.stdin.buffer.read(MAX_IN + 1)
    try:
        if len(raw) > MAX_IN:
            raise Unreadable("entrada-grande")
        v, why, paths, tests, info = classify(load_bead(raw.decode("utf-8", "replace")))
    except Unreadable as e:
        v, why, paths, tests, info = "unknown", ["nao-consegui:" + str(e)], [], [], []
    except Exception as e:   # o que eu não previ (JSON aninhado demais, disco cheio no mkdtemp...) também é "não consegui": nunca um crash que o chamador leia como outra coisa
        v, why, paths, tests, info = "unknown", ["erro-inesperado:" + type(e).__name__], [], [], []
    # basis: de onde veio o `node` — a etiqueta de um humano ou só a prova no texto (o Pilot liga uma e a outra em degraus: modo label, depois auto)
    basis = "label" if "etiqueta-node:ok" in why else ("text" if v == "node" else "")
    print(json.dumps({"verdict": v, "basis": basis, "reasons": why, "paths": paths, "tests": tests, "info": info}, ensure_ascii=False))
    return {"node": EX_NODE, "mini": EX_MINI}.get(v, EX_UNKNOWN)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
