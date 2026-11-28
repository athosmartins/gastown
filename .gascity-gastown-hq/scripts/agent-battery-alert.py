#!/usr/bin/env python3
"""agent-battery-alert.py — queda da taxa da bateria de agentes: aviso ao Mayor, rótulo de revisão no merge causador e controle negativo (ga-hyp55ss.4, fatia 4).

## Contents
  Uso · A regra da queda · O merge causador · Estado · Controle negativo · Códigos de saída  (runbook: docs/runbooks/agent-battery-alert.md)

USO: agent-battery-alert.py [sweep] [--city DIR] [--janela N] [--min-noites N] [--limiar X] [--alfa X] [--max-marcar N] [--mail CMD] [--bd CMD]
     agent-battery-alert.py control [--role PAPEL] [--prompt CAMINHO] [--control-timeout-s S] [as opções acima]       (cada opção também vem de ABA_<NOME>)
A REGRA DA QUEDA: lê as linhas NOVAS de <cidade>/.gc/logs/agent-battery.jsonl (as que o driver da fatia 3 grava) e, para cada papel medido (cat ok), compara a taxa com a MEDIANA das últimas
  --janela noites do MESMO acervo (o sha256 do acervo vem na linha; linha sem ele não se compara). Queda = a taxa ficou ao menos --limiar abaixo da mediana E a chance de ver tantos acertos, se o papel
  ainda acertasse a mediana, é no máximo --alfa (binomial, mediana presa a no máximo 95%). Do tamanho do limiar mas cabendo na sorte = "ruído": só vai ao log. Menos de --min-noites noites de base = sem base:
  não avisa. Avisa UMA vez por queda: a mesma configuração ainda baixa na noite seguinte não repete (volta a valer quando a taxa se recupera ou a configuração muda).
  Linha gravada com --role-prompt (o controle negativo, ou um teste à mão) não é uma rodada: fica fora da base e do aviso, e nunca marca bead.
O MERGE CAUSADOR: a queda é julgada contra a LINHA DE BASE (as noites da mediana), então é dela que a janela parte: acha a noite mais recente da base cuja configuração (`config_sha`) NÃO é a de agora e lista os
  commits entre o `config_ref_sha` dela e o desta medição que tocam os caminhos de configuração do executor (.claude/, CLAUDE.md, <cidade>/CLAUDE.md e o prompt do papel), tira a bead do assunto `tipo(ga-<bead>): ...`
  (só id do HQ: o bd -C <cidade> não acha bead de outro rig) e põe o rótulo audit:bateria-queda e um comentário com os números em cada uma (no máximo --max-marcar: acima disso não marca ninguém). A base inteira já
  com a configuração de agora = nenhum merge explica a queda: o aviso diz isso e nada é marcado. A noite de que a janela partiria sem sha ou commit legível, ou git sem resposta = não sei: o aviso sai sem marca.
ESTADO: <cidade>/.gc/agent-battery/alert-state.json (quantas linhas do jsonl já foram vistas e o papel em queda); decisões em <cidade>/.gc/logs/agent-battery-alert.jsonl. A 1a varredura só grava a base.
  E-mail que falha = a linha NÃO é dada como vista (a próxima varredura tenta de novo; se o estado não grava, o MESMO aviso sai de novo: entrega pelo menos uma vez) e nada é marcado antes dele. O e-mail só PEDE as
  marcas: a que falha vira um 2o e-mail (MARCA FALHOU) e exit 1, o log grava `marcadas` (o rótulo entrou) e `marcas_falhas` por bead, e a varredura não as refaz. Estado ilegível = exit 1 e nada é avaliado: apague-o.
CONTROLE NEGATIVO: `control` roda o driver da noite UMA vez, numa cidade descartável (o jsonl e o relatório reais não são tocados), com --role-prompt PAPEL=scripts/agent-battery-control-prompt.md: o
  executor lê esse prompt deliberadamente inútil NO LUGAR do prompt do papel, no nó, sem commit nenhum (a main não muda). Julga a taxa contra a linha de base REAL pela mesma regra e manda o resultado
  ao Mayor: PASSOU (a taxa caiu e o aviso teria disparado) · FALHOU (a bateria não enxergou a regressão, ou não mediu) · INERTE (sem base, sem acervo, sem credencial, nó desligado). Gasta tokens de verdade.
CÓDIGOS: 0 varredura feita, ou controle PASSOU/INERTE · 1 e-mail, marca ou estado que falhou, ou controle FALHOU · 2 uso errado.
"""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import math
import os
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SHA40, SHA64 = re.compile(r"^[0-9a-f]{40}\Z"), re.compile(r"^[0-9a-f]{64}\Z")
BEAD = re.compile(r"^[a-z]+\((ga-[a-z0-9]+(?:\.[0-9]+)*)\)")  # só id do HQ: o store do HQ não acha id de outro rig (wa-, ...: medido com `bd show`, não com `label add`), e cada marca que falha gasta o teto de --max-marcar
LABEL = "audit:bateria-queda"
OPTS = (("janela", 5, int), ("min-noites", 3, int), ("limiar", 0.20, float), ("alfa", 0.10, float), ("max-marcar", 5, int), ("mail", "", str), ("bd", "bd", str),
        ("role", "dog", str), ("prompt", "scripts/agent-battery-control-prompt.md", str), ("control-timeout-s", 9600, int))

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def say(msg):
    print("%s agent-battery-alert: %s" % (now(), msg), flush=True)

def first(s, n=160):
    return next((x.strip()[:n] for x in s.splitlines() if x.strip()), "")

def pct(x):
    return "%.0f%%" % (100 * x)

def run(argv, timeout):
    """(rc, out, err); rc None = não rodou ou estourou o prazo (o grupo todo é morto): 'não sei', nunca 0."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="replace", start_new_session=True)
    except (OSError, ValueError):
        return None, "", ""
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", ""
    return p.returncode, out, err

def sibling(name):
    """módulo de scripts/<name>.py (o nome tem hífen, o import normal não serve); None = não carregou: o que depende dele vira 'não sei'."""
    try:
        spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except (OSError, ImportError, SyntaxError, AttributeError):
        return None

# ── a regra da queda ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def measure(rec):
    """(acertos, medidas, acervo) de um papel medido (cat ok, contagens inteiras e coerentes); acervo None = a linha não o traz (formato antigo ou torto). None = não é uma medida."""
    if not isinstance(rec, dict) or rec.get("cat") != "ok":
        return None
    k, n, ac = rec.get("ok"), rec.get("medidas"), rec.get("acervo")
    if not all(isinstance(x, int) and not isinstance(x, bool) for x in (k, n)) or n < 1 or not 0 <= k <= n:
        return None
    return k, n, ac if isinstance(ac, str) and SHA64.match(ac) else None

def p_sorte(k, n, p0):
    """P(X <= k), X ~ Binomial(n, p0): a chance de ver k acertos ou menos em n tarefas se o papel ainda acertasse p0. p0 preso a no máximo 95%: uma base de 100% não quer dizer p=1."""
    p0 = min(p0, 0.95)
    return sum(math.comb(n, i) * p0 ** i * (1 - p0) ** (n - i) for i in range(k + 1))

def base_nights(a, hist, role, acervo):
    """[(taxa, config_sha, config_ref_sha, ts)] das últimas --janela noites medidas do papel no mesmo acervo, da mais antiga à mais nova: a LINHA DE BASE, e a configuração em que cada noite foi medida.
    Só noites: uma medida de merge é, por construção, a de uma configuração que acabou de mudar."""
    nights = []
    for l in hist:
        rec = (l["papeis"] or {}).get(role)
        b = measure(rec) if l.get("mode") == "night" else None
        if b and b[2] == acervo:
            # vazio/falhou (a noite não traz o sha de configuração ou o commit) → None aqui; merges() diz "não sei" se for dessa noite que a janela parte; a taxa vale do mesmo jeito
            nights.append((b[0] / b[1], rec.get("config_sha"), rec.get("config_ref_sha"), l["ts"]))
    return nights[-a.janela:]

def judge_drop(a, hist, role, rec):
    """Veredito de um papel: {kind, taxa, k, n, base, noites, queda, p, nights}; kind = sem_acervo | sem_base | ok | ruido | queda; `nights` = a linha de base (base_nights) quando houve. None = não é uma medida. `hist` = linhas anteriores (dicts)."""
    m = measure(rec)
    if m is None:
        return None
    k, n, ac = m
    v = {"taxa": k / n, "k": k, "n": n, "base": None, "noites": 0, "queda": None, "p": None}
    if ac is None:
        return dict(v, kind="sem_acervo")
    nights = base_nights(a, hist, role, ac)
    v["noites"] = len(nights)
    if len(nights) < a.min_noites:
        return dict(v, kind="sem_base")
    base = statistics.median(t[0] for t in nights)
    queda, p = round(base - v["taxa"], 4), p_sorte(k, n, base)
    return dict(v, kind="ok" if queda < a.limiar else ("queda" if p <= a.alfa else "ruido"), base=base, queda=queda, p=p, nights=nights)

def fmt(role, v):
    t = "%s: %s (%d/%d tarefas)" % (role, pct(v["taxa"]), v["k"], v["n"])
    if v["base"] is None:
        return "%s; sem linha de base comparável (%d noite(s) do mesmo acervo)" % (t, v["noites"])
    return "%s contra %s de mediana das últimas %d noites do mesmo acervo: %+.0f pp%s" % (
        t, pct(v["base"]), v["noites"], -100 * v["queda"], "; chance de ser sorte %s" % ("<0.1%" if v["p"] < 0.001 else "%.1f%%" % (100 * v["p"])) if v["queda"] > 0 else "")

# ── leitura do jsonl e do estado ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
def read_jsonl(path, control=False):
    """Uma entrada por linha COMPLETA (dict, ou None = não é uma linha de rodada: lixo, ou medida com o prompt de um papel trocado, que só o controle lê); None = o arquivo não leu.
    vazio (sem arquivo) → []; falhou/ilegível (permissão, disco) → None: nada é avaliado."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except FileNotFoundError:
        return []
    except OSError:
        return None
    out = []
    for raw in text.split("\n")[:-1]:  # o último pedaço, sem "\n", é uma linha ainda sendo gravada: fica para a próxima varredura
        try:
            d = json.loads(raw)
        except ValueError:
            d = None
        out.append(d if isinstance(d, dict) and isinstance(d.get("ts"), str) and isinstance(d.get("papeis"), dict) and (control or not d.get("role_prompt")) else None)
    return out

def save(path, d):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".new", "w", encoding="utf-8") as f:
            json.dump(d, f, sort_keys=True)
        os.replace(path + ".new", path)
    except OSError as e:
        say("WARN: não gravei %s (%s)" % (path, e))
        return False
    return True

def audit(a, rows):
    # vazio → nada a gravar; falhou ao gravar → só avisa e a varredura segue (o e-mail já saiu e o estado é gravado logo depois): o log é a trilha das decisões, não a decisão
    if not rows:
        return
    try:
        os.makedirs(os.path.join(a.city, ".gc/logs"), exist_ok=True)
        with open(os.path.join(a.city, ".gc/logs/agent-battery-alert.jsonl"), "a", encoding="utf-8") as f:
            f.writelines(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows)
    except OSError as e:
        say("WARN: não gravei o log de decisões (%s)" % e)

# ── o merge causador ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def merges(a, role, v):
    """([(sha, bead|None, assunto)], nota): os commits que tocam a configuração do papel entre a noite da linha de base em que a configuração MUDOU e esta medição. A janela parte da base porque é contra ela que a queda foi
    julgada: a medição anterior pode já ser da configuração nova (um merge que ficou em ruído). A nota diz sempre o que se sabe ou por que não se sabe: sem commits e sem leitura têm notas diferentes."""
    if not (SHA64.match(str(v["sha"])) and SHA40.match(str(v["ref"]))):
        return [], "a linha não traz o sha de configuração e o commit medido"
    # vazio (nenhuma noite da base com outro sha: o laço acaba sem break) → a base inteira já tinha esta configuração; falhou/ilegível (a noite não traz o sha ou o commit) → "não sei", nunca "não mudou"
    # (`queda` exige --min-noites >= 1 noites de base: o laço nunca roda sobre uma base vazia)
    for _, psha, pref, pts in reversed(v["nights"]):
        if psha != v["sha"]:
            break
    else:
        return [], "a configuração do papel é a mesma de toda a linha de base (%d noites): a queda não vem de um merge de prompt, skill ou CLAUDE.md" % len(v["nights"])
    if not (SHA64.match(str(psha)) and SHA40.match(str(pref))):
        return [], "não sei desde quando a configuração mudou: a noite de %s da linha de base não traz o sha de configuração e o commit medido" % pts
    abr = sibling("agent-battery-run")  # vazio → n/a; falhou ao carregar → sem os caminhos do executor não sei o que olhar: sem lista
    # vazio → n/a; falhou (git sem resposta, fora de um repositório: o stdout vem vazio) → sem raiz nem prefixo não sei onde olhar: sem lista
    top = run(["git", "-C", a.city, "rev-parse", "--show-toplevel", "--show-prefix"], 30)[1]
    root, _, pre = top.partition("\n")
    if abr is None or not root or role not in abr.ROLE_PROMPTS:
        return [], "não consegui montar os caminhos de configuração do papel (executor, git ou papel desconhecido)"
    pre = pre.strip().strip("/")
    paths = list(abr.CONFIG_PATHS) + ([pre + "/CLAUDE.md"] if pre else []) + [os.path.join(pre, abr.ROLE_PROMPTS[role])]
    # vazio (nenhum commit toca os caminhos) → nota própria; falhou (sha que o clone não tem, git morto) → "não sei", nunca "nenhum commit"
    rc, out, err = run(["git", "-C", root, "log", "--format=%H%x09%s", "%s..%s" % (pref, v["ref"]), "--"] + paths, 60)
    if rc != 0:
        return [], "não consegui listar os commits entre %s e %s (git: %s)" % (pref[:12], v["ref"][:12], first(err, 100) or "sem resposta")
    found = [(sha, (BEAD.match(subj) or [None, None])[1], subj) for sha, _, subj in (ln.partition("\t") for ln in out.splitlines())]
    desde = "desde a noite de %s da linha de base" % pts
    return found, ("mudou " + desde) if found else "o sha de configuração mudou %s, mas nenhum commit entre %s e %s toca os caminhos do papel" % (desde, pref[:12], v["ref"][:12])

def pick(a, cul):
    """({bead: [papéis]}, motivo): as beads a marcar; mais de --max-marcar candidatas = nenhuma (um intervalo grande demais não aponta ninguém)."""
    beads = {}
    for role, (found, _) in sorted(cul.items()):
        for _, bead, _ in found:
            if bead and role not in beads.setdefault(bead, []):
                beads[bead].append(role)
    if len(beads) > a.max_marcar:
        return {}, "são %d beads candidatas (máximo %d): não marquei nenhuma" % (len(beads), a.max_marcar)
    return beads, ""

def mail_argv(a):
    return shlex.split(a.mail) if a.mail else ["gc", "--city", a.city, "mail", "send", "mayor"]

def render(a, line, fired, cul, beads, why):
    day = line.get("dia") or line["ts"][:10]
    out = ["Queda da taxa na bateria de agentes: %s (%s), medida em %s." % (day, line.get("mode"), line["ts"]), ""]
    for role, v in sorted(fired.items()):
        found, nota = cul[role]
        out += ["- " + fmt(role, v), "  configuração %s (commit medido %s): %s" % (str(v["sha"])[:12], str(v["ref"])[:12], nota)]
        out += ["  commits que mexeram na configuração do papel desde essa noite:"] * bool(found) + ["    - %s %s: %s" % (s[:12], b or "(sem bead do HQ no assunto)", subj[:120]) for s, b, subj in found]
    # as marcas só são PEDIDAS depois deste e-mail: o texto não pode dizer que já entraram (o bd ainda não respondeu); que alguma falhou dizem o 2o e-mail, o log e o exit 1
    out += [""] + (["Marcas a pôr logo depois deste e-mail (rótulo %s e um comentário com os números): %s. Se alguma falhar, um 2º e-mail diz qual; confira com o comando abaixo." % (LABEL, ", ".join(sorted(beads)))] if beads else ["Não marquei nenhuma bead%s." % (": " + why if why else "")])
    out += ["Ver todas: bd list --label %s --limit 0. Tirar a marca: bd label remove <bead> %s." % (LABEL, LABEL),
            "A queda pode ser ruído (amostra pequena), do modelo ou do nó, ou de OUTRO commit do intervalo: confira antes de reverter. Relatório do dia: .gc/logs/agent-battery/%s.md." % day]
    return "[agent-battery] QUEDA %s (%s): %s" % (day, line.get("mode"), ", ".join("%s %s→%s" % (r, pct(v["base"]), pct(v["taxa"])) for r, v in sorted(fired.items()))), "\n".join(out)

def mark(a, bead, line, rows):
    """(rotulada, falha): rotulada = o rótulo entrou (a bead ESTÁ marcada); falha = "" se o rótulo E o comentário entraram, senão a frase do que não entrou. Rótulo que falha = o comentário nem é tentado."""
    text = "\n".join(["[bateria de agentes] a taxa de um papel caiu depois deste merge, que mexeu na configuração dele (rótulo %s):" % LABEL]
                     + ["- " + fmt(r, v) + " (medição %s)" % line["ts"] for r, v in sorted(rows.items())]
                     + ["Pode ser ruído ou outro commit do intervalo; revise o prompt/skill/CLAUDE.md deste merge. Para tirar: bd label remove %s %s." % (bead, LABEL)])
    base = shlex.split(a.bd) + ["-C", a.city]
    rc, _, err = run(base + ["label", "add", bead, LABEL], 60)
    if rc != 0:
        return False, "não marquei %s (rótulo: %s)" % (bead, first(err, 100) or "sem resposta")
    rc, _, err = run(base + ["comment", bead, text], 60)
    return True, "" if rc == 0 else "marquei %s, mas SEM o comentário com os números (%s)" % (bead, first(err, 100) or "sem resposta")

# ── a varredura ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def verdicts(a, st, hist, line):
    """{papel: veredito} das medidas da linha; 'persistente' = a mesma configuração que já avisou e segue baixa (não repete o aviso)."""
    out = {}
    for role, rec in sorted(line["papeis"].items()):
        v = judge_drop(a, hist, role, rec)
        if v is None:
            continue
        ps = st["papeis"].get(role) if isinstance(st["papeis"].get(role), dict) else {}
        if v["kind"] == "queda" and ps.get("alerta") and ps.get("sha") == rec.get("config_sha"):
            v["kind"] = "persistente"
        out[role] = dict(v, sha=rec.get("config_sha"), ref=rec.get("config_ref_sha"))
    return out

def announce(a, line, fired):
    """(enviado, candidatas, marcadas, falhas): o e-mail com as quedas da linha e, só DEPOIS dele, as marcas (e-mail que falha não deixa marca órfã nem comentário repetido na volta seguinte). O e-mail só PEDE as marcas:
    candidatas = {bead: papéis}; marcadas = as que ficaram com o rótulo; falhas = {bead: o que não entrou}, e um 2o e-mail as diz (a varredura não as refaz)."""
    cul = {r: merges(a, r, v) for r, v in fired.items()}
    beads, why = pick(a, cul)
    subj, body = render(a, line, fired, cul, beads, why)
    if run(mail_argv(a) + ["-s", subj, "-m", body], 120)[0] != 0:
        return False, {}, [], {}
    done, fails = [], {}
    for bead, roles in sorted(beads.items()):
        labeled, err = mark(a, bead, line, {r: fired[r] for r in roles})
        if labeled:
            done.append(bead)
        if err:
            fails[bead] = err
    if fails:
        msg = ["Marca(s) do aviso de queda de %s que NÃO entraram inteiras; a varredura não as refaz. À mão, só o que faltou: rótulo = bd -C %s label add <bead> %s; comentário = os números do aviso (bd -C %s comment <bead> ...):" % (line["ts"], a.city, LABEL, a.city)] + ["- " + f for _, f in sorted(fails.items())]
        if run(mail_argv(a) + ["-s", "[agent-battery] MARCA FALHOU: " + ", ".join(sorted(fails)), "-m", "\n".join(msg)], 120)[0] != 0:
            say("WARN: o e-mail das marcas que falharam também falhou")
    return True, beads, done, fails

def sweep(a):
    jl, sp = os.path.join(a.city, ".gc/logs/agent-battery.jsonl"), os.path.join(a.city, ".gc/agent-battery/alert-state.json")
    lines = read_jsonl(jl)
    if lines is None:
        say("WARN: não consegui ler %s: nada avaliado" % jl)
        return 1
    # vazio (sem arquivo) → 1a varredura: grava a base e não avalia; falhou/ilegível (existe e não lê, ou não tem a forma {linhas, papeis}) → exit 1 sem avaliar nem gravar: não sei o que já foi avisado
    try:
        with open(sp, encoding="utf-8") as f:
            st = json.load(f)
    except FileNotFoundError:
        st = None
    except (OSError, ValueError):
        st = False
    if st is not None and not (isinstance(st, dict) and isinstance(st.get("linhas"), int) and not isinstance(st["linhas"], bool) and st["linhas"] >= 0 and isinstance(st.get("papeis"), dict)):
        say("WARN: %s ilegível: nada avaliado (apague-o para regravar a base)" % sp)
        return 1
    if st is None or len(lines) < st["linhas"]:  # 1a varredura, ou o jsonl encolheu: não sei o que já foi visto, e reavaliar o histórico seria uma enxurrada de avisos velhos
        say("%s: base gravada (%d linhas do jsonl), nada avaliado" % ("primeira varredura" if st is None else "o jsonl tem menos linhas do que eu já vi (%d)" % st["linhas"], len(lines)))
        return 0 if save(sp, {"linhas": len(lines), "papeis": (st or {}).get("papeis", {})}) else 1
    code, bad = 0, sum(1 for l in lines[st["linhas"]:] if l is None)
    if bad:
        say("WARN: %d linha(s) nova(s) do jsonl que não são uma rodada: ignoradas" % bad)
    for i in range(st["linhas"], len(lines)):
        line = lines[i]
        if line is not None:
            hist = [l for l in lines[:i] if l]
            vs = verdicts(a, st, hist, line)
            fired = {r: v for r, v in vs.items() if v["kind"] == "queda"}
            sent, beads, done, fails = announce(a, line, fired) if fired else (True, {}, [], {})
            if not sent:  # nada avança: nem o estado desta linha, para a próxima varredura tentar de novo
                say("WARN: o e-mail ao Mayor falhou: a linha de %s fica para a próxima varredura" % line["ts"])
                return 1
            for role, v in vs.items():
                if v["kind"] in ("queda", "ok"):
                    st["papeis"][role] = {"alerta": v["kind"] == "queda", "sha": v["sha"], "ts": line["ts"]}
                say("%s %s %s: %s" % (line["ts"], role, v["kind"], fmt(role, v)))
            audit(a, [{"ts": now(), "linha": line["ts"], "mode": line.get("mode"), "papel": r, "kind": v["kind"], "taxa": v["taxa"], "base": v["base"], "noites": v["noites"], "queda": v["queda"],
                       "p": v["p"], "marcadas": sorted(b for b in done if r in beads[b]), "marcas_falhas": {b: e for b, e in sorted(fails.items()) if r in beads[b]}} for r, v in vs.items()])
            for f in fails.values():
                say("WARN: " + f)
            code = 1 if fails else code
        st["linhas"] = i + 1
        if not save(sp, st):
            return 1
    return code

# ── o controle negativo ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def control_run(a, hist):
    """(veredito, motivo, veredito_da_queda|None): PASSOU | FALHOU | INERTE."""
    drv = sibling("agent-battery-night")
    if drv is None:
        return "FALHOU", "não consegui carregar o driver da noite (agent-battery-night.py)", None
    ns = os.environ.get("ABN_NODE_STATE") or dict((n, d) for n, d, _ in drv.OPTS)["node-state"]
    # O controle gasta tokens de verdade: sem base para julgar ele nem roda. O acervo medido é o sha256 do tasks.jsonl (o executor faz o mesmo).
    # vazio (sem acervo) → INERTE sem gastar; falhou ao ler (existe e não lê) → FALHOU: não sei qual acervo seria medido
    try:
        with open(os.path.join(a.city, ".gc/agent-battery/tasks.jsonl"), "rb") as f:
            ac = hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return "INERTE", "sem acervo em .gc/agent-battery/tasks.jsonl (rode scripts/agent-battery-corpus.py): nada foi gasto", None
    except OSError as e:
        return "FALHOU", "não consegui ler o acervo (%s): nada foi gasto" % e, None
    noites = len(base_nights(a, [l for l in hist if l], a.role, ac))
    if noites < a.min_noites:
        return "INERTE", "sem linha de base real: %d noite(s) do papel %s no acervo de hoje (mínimo %d); o controle gastaria tokens sem poder ser julgado" % (noites, a.role, a.min_noites), None
    scratch = None  # vazio → nada a limpar; falhou ao criar (disco cheio) → o OSError cai no except abaixo: FALHOU e e-mail, nunca traceback
    try:
        scratch = tempfile.mkdtemp(prefix="aba-control-")
        st = os.path.join(scratch, ".gc/agent-battery")
        os.makedirs(st)
        for n in ("tasks.jsonl", "tasks.jsonl.meta.json"):  # vazio (sem acervo) → o driver diz INERTE; falhou ao copiar → o OSError sobe para o try de fora
            with contextlib.suppress(FileNotFoundError):
                shutil.copyfile(os.path.join(a.city, ".gc/agent-battery", n), os.path.join(st, n))
        if os.path.exists(os.path.join(a.city, ".gc/hetzner-node.on")):
            open(os.path.join(scratch, ".gc/hetzner-node.on"), "w").close()
        rc, out, err = run([sys.executable, "-I", os.path.join(HERE, "agent-battery-night.py"), "--mode", "night", "--city", scratch, "--roles", a.role, "--role-prompt", "%s=%s" % (a.role, a.prompt),
                            "--node-state", ns + "-control", "--mail", "true"], a.control_timeout_s)
        # vazio (nenhuma linha: o driver nem chegou ao fim) → FALHOU; falhou ao ler → o mesmo: o controle não mediu
        cl = read_jsonl(os.path.join(scratch, ".gc/logs/agent-battery.jsonl"), True) or []
        last = next((l for l in reversed(cl) if l), None)
    except OSError as e:
        return "FALHOU", "não consegui preparar a cidade descartável (%s)" % e, None
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    if last is None:
        return "FALHOU", "o driver não deixou linha no jsonl (rc %s): %s" % (rc, first(err or out)), None
    why = "o driver disse %s: %s" % (last.get("verdict"), last.get("reason"))
    if last.get("verdict") in ("INERTE", "PULADO"):
        return "INERTE", why, None
    v = judge_drop(a, [l for l in hist if l], a.role, (last["papeis"] or {}).get(a.role))
    if last.get("verdict") != "COMPLETO" or v is None:
        return "FALHOU", why, None
    if v["kind"] in ("sem_base", "sem_acervo"):
        return "INERTE", "sem linha de base real para julgar a queda (%d noite(s) do mesmo acervo, mínimo %d)" % (v["noites"], a.min_noites), v
    if v["kind"] == "queda":
        return "PASSOU", "a taxa caiu com o prompt ruim e o aviso teria disparado", v
    return "FALHOU", "a bateria NÃO enxergou a regressão (%s): %s" % (v["kind"], "a queda coube na sorte" if v["kind"] == "ruido" else "a taxa não caiu o bastante"), v

def control(a):
    # vazio (sem jsonl real) → sem base, o julgamento vira INERTE; falhou ao ler → não sei julgar: FALHOU
    hist = read_jsonl(os.path.join(a.city, ".gc/logs/agent-battery.jsonl"))
    res = ("FALHOU", "não consegui ler o jsonl real da bateria", None) if hist is None else control_run(a, hist)
    verdict, why, v = res
    day = now()[:10]
    body = ["Controle negativo da bateria de agentes (%s), papel %s: %s." % (day, a.role, verdict), why, ""] + ([fmt(a.role, v)] if v is not None else []) + [
        "Nada vai para o git: o prompt ruim (%s) só é lido pelo executor, no nó, no lugar do prompt do papel, quando o controle roda; a main e o jsonl real não mudam." % a.prompt]
    say("CONTROLE %s: %s" % (verdict, why))
    sent = run(mail_argv(a) + ["-s", "[agent-battery] CONTROLE NEGATIVO %s: %s (%s)" % (day, verdict, a.role), "-m", "\n".join(body)], 120)[0] == 0
    if not sent:
        say("WARN: o e-mail ao Mayor falhou")
    print("CONTROLE: " + verdict, flush=True)
    return 1 if verdict == "FALHOU" or not sent else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", choices=("sweep", "control"), default="sweep")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.path.dirname(HERE))
    for name, default, typ in OPTS:
        ap.add_argument("--" + name, type=typ, default=os.environ.get("ABA_" + name.upper().replace("-", "_"), default))
    a = ap.parse_args()
    if a.janela < 1 or not 1 <= a.min_noites <= a.janela or not 0 < a.limiar <= 1 or not 0 < a.alfa < 1 or a.max_marcar < 0 or a.control_timeout_s < 1:
        print("agent-battery-alert: --janela >= 1, 1 <= --min-noites <= --janela, 0 < --limiar <= 1, 0 < --alfa < 1, --max-marcar >= 0 e prazo positivo", file=sys.stderr)
        return 2
    os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin")
    return control(a) if a.cmd == "control" else sweep(a)

if __name__ == "__main__":
    sys.exit(main())
