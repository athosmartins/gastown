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
     `node:ok` dispensa a prova (as duras já passaram) -> node, basis `label`; sem prova -> unknown

CÓDIGOS DE SAÍDA: 0 node · 10 mini · 11 unknown · 2 uso. A linha de stdout é um JSON: {"verdict","basis","reasons":[...],"paths":[...],"tests":[...],"info":[...]}.
O QUE NÃO FAZ: não lê dado, não abre o nó, não toca o Dolt, não escreve na bead. Lê só stdin (o JSON do `bd show --json`), o filtro, a lista mac-only e (só com `.md` fora do rsync) o filtro que o espelho serve.
LIMITES: a exceção do espelho confia na varredura de conteúdo (>=20 telefones ou >=3 CPFs distintos por arquivo): lista pequena, nome, e-mail e CNPJ num `.md` passam; vale o mesmo resíduo do bloco 3b do filtro. É heurística de TEXTO sobre a bead; o texto pode omitir que o teste abre um banco. NÃO são extraídos: pasta sem arquivo (`data/`), arquivo sem nome (`.env`), extensão fora da lista, nome com
  sufixo (`x.py.bak` não vira `x.py`). Para esses a regra 3a não age; quem segura o dado é o filtro do rsync (o nó nunca o recebe) e, no caso de `.env`/`.db`, a palavra mole da regra 4. O resíduo cai no nó como teste vermelho e a bead volta ao mini pelo gate (custo, não vazamento:
  o dado não chega ao nó de qualquer jeito). A lista de palavras moles é deliberadamente larga (o vocabulário do WA é todo de lead/terreno): na dúvida a bead fica no mini, como hoje.
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
    globs = mac_only_globs() if paths else []
    # texto neutro que o rsync não lista mas o espelho entrega (docs/, DESIGN.md...): só os .md fora da lista pagam a consulta ao espelho; os demais caminhos seguem como antes.
    # vazio (nenhum .md fora da lista) -> o espelho nem é consultado; falhou/ilegível -> nenhum chega e `info` leva espelho-ilegivel:<motivo> (o caminho segue 'fora do filtro' = mini, como antes desta regra)
    via_mirror, note = mirror_reach([p for p in paths if p not in sent and p.rsplit(".", 1)[-1].lower() in MIRROR_TEXT_EXT]) if paths else ([], [])
    info += note + ["via-espelho:" + p for p in via_mirror]
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
    return "unknown", ["sem-prova-de-codigo-e-teste"], paths, tests, info


def main(argv):
    if len(argv) > 1:
        sys.stderr.write("uso: wa-node-classify.py < bead.json   (o JSON do `bd show <id> --json`)\n")
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
