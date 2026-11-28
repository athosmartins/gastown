#!/usr/bin/env python3
"""agent-battery-night.py — ordem noturna e gatilho de merge da bateria de agentes no nó Hetzner (ga-hyp55ss.3, fatia 3).

## Contents
  Uso · O que faz · Veredito · Gatilho de merge · Segurança · Códigos de saída  (runbook: docs/runbooks/agent-battery-night.md)

USO: agent-battery-night.py [--mode night|merge] [--city DIR] [--node HOST] [--ssh CMD] [--mail CMD] [--token-cmd CMD] [--roles A,B,C]
        [--night-cap N] [--merge-cap N] [--min-medidas N] [--limit N] [--run-timeout-s S] [--keep-days N] [--prefix P] [--config-ref REF]
        [--node-repo DIR] [--node-state DIR]            (cada opção também vem de ABN_<NOME>, ex.: ABN_TOKEN_CMD)
O QUE FAZ: manda o acervo da fatia 1 (<cidade>/.gc/agent-battery/tasks.jsonl + .meta.json) ao nó e roda o executor da fatia 2 (agent-battery-run.py,
  SEMPRE o do origin/main do nó) uma vez por papel (dog, wa-worker, reviewer), em paralelo, cada um com o próprio estado e o próprio teto de tokens
  (--night-cap/--merge-cap são POR PAPEL). Grava a taxa por papel com o config_sha em <cidade>/.gc/logs/agent-battery.jsonl (uma linha por rodada da noite e por medida de merge),
  o relatório em <cidade>/.gc/logs/agent-battery/<dia>.md (merge: <dia>-merge-<hora>.md; apagados com 14 dias) e avisa o Mayor por e-mail. Só mede e avisa: não bloqueia merge e não compara com
  a noite anterior (isso é a fatia 4).
VEREDITO (última linha do stdout, `VEREDITO: <x>`): COMPLETO = todo papel com ao menos --min-medidas tarefas medidas (freio de tokens com amostra
  suficiente conta) · INERTE = nada pôde rodar por falta de pré-requisito (sem acervo ou sem tarefa utilizável, sem credencial, claude ausente no nó), o e-mail diz o quê ·
  FALHOU = não dá para dizer o que aconteceu (nó fora, executor ausente ou morto pelo prazo, resumo ilegível, papel sem amostra, mistura de resultados) ·
  PULADO = por escolha, com motivo (nó desligado, outra rodada em andamento, executor ocupado no nó). Um papel nunca vira taxa 0 por não ter sido medido.
GATILHO DE MERGE (--mode merge, ordem por cooldown): a cada sondagem pergunta ao nó, por `--dry-run` do executor (sem token, sem gasto), o config_sha de
  cada papel e só roda o papel cujo sha difere do último medido (<cidade>/.gc/agent-battery/merge-last.json, gravado pela noite e pelo merge). A 1ª
  sondagem só grava a base. Uma mudança é tentada UMA vez (falhou? a noite repete). O merge só fala quando um papel chegou a rodar: relatório e jsonl em
  COMPLETO/FALHOU, e-mail só em FALHOU; PULADO/INERTE e falha ANTES de medir (nó fora, acervo ilegível) viram uma linha de stdout (a noite diz o que falta).
SEGURANÇA: a chave do claude vem do stdout de --token-cmd, segue ao nó só pela entrada padrão do ssh (nunca no argv) e é escondida de relatório,
  jsonl, e-mail e stdout (a chave conhecida e qualquer `sk-ant-…`). O que o executor deixa o agente fazer é da fatia 2 (docs/runbooks/agent-battery-run.md).
CÓDIGOS: 0 COMPLETO/INERTE/PULADO · 1 FALHOU, e-mail ao Mayor que falhou, ou erro inesperado do driver · 2 uso errado.
"""
import argparse
import concurrent.futures
import contextlib
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

ROLES = ("dog", "wa-worker", "reviewer")
KNOWN = ("dog", "wa-worker", "ps-worker", "reviewer")
CODE_REF = "origin/main"  # o executor roda SEMPRE do main; --config-ref é só a configuração sob teste
TOKEN_RE = re.compile(r"^[\x21-\x7e]{20,512}\Z")
SECRET_RE = re.compile(r"sk-ant-[A-Za-z0-9_-]+")
NOT_STARTED = "nao_iniciou"
SECRETS = []
EMPTY = {"rc": None, "config_sha": None, "medidas": None, "ok": None, "taxa": None, "por_estado": None, "freio": None, "tokens": None, "config_ref_sha": None,
         "descartes": None}
OPTS = (("node", "hetzner-teste", str), ("ssh", "ssh -o BatchMode=yes -o ConnectTimeout=20", str), ("mail", "gc mail send mayor", str),
        ("token-cmd", "", str), ("roles", ",".join(ROLES), str), ("night-cap", 1200000, int), ("merge-cap", 1200000, int),
        ("min-medidas", 5, int), ("limit", 0, int), ("run-timeout-s", 9000, int), ("keep-days", 14, int), ("prefix", ".gascity-gastown-hq", str),
        ("config-ref", "origin/main", str), ("node-repo", "/home/runner/gt-remote/git/gascity/repo.git", str),
        ("node-state", "/home/runner/gt-remote/agent-battery", str))

def now(fmt="%Y-%m-%dT%H:%M:%SZ"):
    return time.strftime(fmt, time.gmtime())

def scrub(s):
    for x in SECRETS:
        s = s.replace(x, "***")
    return SECRET_RE.sub("sk-ant-***", s)

def say(msg):
    print(scrub("%s agent-battery-night: %s" % (now(), msg)), flush=True)

def die(code, msg):
    print("agent-battery-night: " + scrub(msg), file=sys.stderr)
    sys.exit(code)

def top(d, n=3):
    """'motivo ×n, ...' dos n maiores contadores de um dicionário do executor; o que não for dicionário vira '-', nunca um erro."""
    if not isinstance(d, dict):
        return "-"
    return ", ".join("%s ×%s" % kv for kv in sorted(d.items(), key=lambda kv: (-kv[1] if isinstance(kv[1], int) else 0, kv[0]))[:n]) or "-"

def first(s, n=200):
    return next((x.strip()[:n] for x in s.splitlines() if x.strip()), "")

def run(argv, timeout, stdin=b""):
    """(rc, out, err); rc NOT_STARTED = o exec falhou, None = estourou o prazo (o grupo todo é morto): os dois são 'não sei', nunca 0."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except (OSError, ValueError):
        return NOT_STARTED, "", ""
    try:
        out, err = p.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", ""
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

def ssh(a, cmd, timeout, stdin=b""):
    return run(shlex.split(a.ssh) + [a.node, cmd], timeout, stdin)

def upload(a, name, data):
    """grava <node-state>/<name> no nó por tmp + mv: cada arquivo chega inteiro; entre os dois, tasks novo com meta velho o executor recusa pelo sha256 (rc 2)."""
    q = shlex.quote
    dest = q("%s/%s" % (a.node_state, name))
    return ssh(a, "mkdir -p %s && cat > %s.new && mv -f %s.new %s" % (q(a.node_state), dest, dest, dest), 120, data)

def remote_cmd(a, mode, role, dry):
    """O que o nó executa: o executor DO MAIN (git show num diretório descartável), o token só pela entrada padrão, `timeout` para nada ficar rodando depois de nós."""
    q = shlex.quote
    cap = a.night_cap if mode == "night" else a.merge_cap
    args = ["--repo", a.node_repo, "--prefix", a.prefix, "--config-ref", a.config_ref, "--state-dir", "%s/%s/%s" % (a.node_state, mode, role),
            "--tasks", a.node_state + "/tasks.jsonl", "--as-role", role, "--token-cap", str(cap)] + (["--limit", str(a.limit)] if a.limit else [])
    steps = ['export PATH="$HOME/.local/bin:$PATH"']
    if not dry:
        steps.append("IFS= read -r CLAUDE_CODE_OAUTH_TOKEN && export CLAUDE_CODE_OAUTH_TOKEN")
    steps += ["T=$(mktemp -d) || exit 97", "trap 'rm -rf \"$T\"' EXIT",
              "git -C %s show %s:%s/scripts/agent-battery-run.py > \"$T/run.py\" || exit 96" % (q(a.node_repo), CODE_REF, q(a.prefix)),
              "timeout -k 30 %d python3 -I \"$T/run.py\" %s%s" % (a.run_timeout_s, " ".join(q(x) for x in args), " --dry-run" if dry else "")]
    return "; ".join(steps)

def probe(a, roles):
    """{papel: config_sha} do --dry-run do executor no nó (sem token, sem gasto). Papel que não respondeu direito fica de fora desta sondagem: não sei ≠ mudou."""
    with concurrent.futures.ThreadPoolExecutor(len(roles)) as ex:
        res = list(ex.map(lambda r: (r, ssh(a, remote_cmd(a, "merge", r, True), 180)), roles))
    out = {}
    for r, (rc, o, _) in res:
        d = parse_summary(o) if rc == 0 else None
        sha = d["config_sha"].get(r) if d else None
        if isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha):
            out[r] = sha
    return out

def parse_summary(out):
    """dict do resumo (a última linha do stdout do executor); None = ilegível — vazio e podre dão o MESMO 'não sei', nunca taxa 0."""
    lines = out.strip().splitlines()
    try:
        d = json.loads(lines[-1]) if lines else None
    except ValueError:
        return None
    return d if isinstance(d, dict) and isinstance(d.get("config_sha"), dict) else None

def judge(a, mode, role, r):
    """(categoria, motivo, registro) de um papel: ok | inerte | pulado | falhou. Resumo ilegível ou rc que não conheço = falhou, nunca taxa 0."""
    rc, err = r["rc"], first(r["err"], 120)
    d = parse_summary(r["out"]) if isinstance(rc, int) else None
    if rc is None or rc == NOT_STARTED:
        return "falhou", "o ssh para %s %s" % (a.node, "estourou o prazo" if rc is None else "não iniciou"), dict(EMPTY, rc=rc)
    rec = dict(EMPTY, rc=rc)
    if d is None:
        # o executor só imprime o resumo quando chegou a rodar: sem ele, o rc diz o que faltou (8 = claude ausente, 3 = acervo sem tarefa, 7 = outra rodada)
        known = {8: ("inerte", err or "claude ou credencial ausente no nó"), 3: ("inerte", "o acervo não tem tarefa utilizável"),
                 7: ("pulado", "outra rodada do executor em andamento no nó"), 255: ("falhou", "nó %s inalcançável (ssh: %s)" % (a.node, err)),
                 96: ("falhou", "executor ausente no nó (git show %s:%s/scripts/agent-battery-run.py falhou)" % (CODE_REF, a.prefix)),
                 97: ("falhou", "mktemp falhou no nó"), 124: ("falhou", "estourou o prazo de %ds: o executor foi morto no nó" % a.run_timeout_s)}
        cat, why = known.get(rc, ("falhou", "sem resumo legível do executor (rc %s)%s" % (rc, ": " + err if err else "")))
        return cat, why, rec
    pp = (d.get("por_papel") or {}).get(role) or {}  # papel ausente = 0 medidas: o executor só lista quem mediu
    n, k, taxa, est = pp.get("medidas", 0), pp.get("ok", 0), pp.get("taxa"), d.get("por_estado")
    rec.update(config_sha=d["config_sha"].get(role), medidas=n, ok=k, taxa=taxa if isinstance(taxa, (int, float)) and not isinstance(taxa, bool) else None,
               por_estado=est if isinstance(est, dict) else None, freio=d.get("freio"), config_ref_sha=d.get("config_ref_sha"), descartes=d.get("descartes"),
               tokens=d.get("tokens_noite_depois", 0) - d.get("tokens_noite_antes", 0))
    if rc not in (0, 6):
        return "falhou", "o executor terminou com rc %s (freio %s)" % (rc, d.get("freio")), rec
    if n >= a.min_medidas:
        return "ok", "", rec
    if mode == "merge" and d.get("freio") == "teto_de_tokens" and n == 0:
        return "pulado", "o teto de tokens do dia já se esgotou", rec
    return "falhou", "%s medidas (mínimo %s; freio %s; estados %s; descartes %s)" % (n, a.min_medidas, d.get("freio") or "-", top(est), top(d.get("descartes"))), rec

def judge_safe(a, mode, role, r):
    try:
        return judge(a, mode, role, r)
    except (TypeError, ValueError, AttributeError, KeyError) as e:  # resumo com forma inesperada: este papel falha sozinho, os outros seguem
        return "falhou", "resumo do executor com forma inesperada (%s)" % type(e).__name__, dict(EMPTY, rc=r["rc"])

def decide(mode, judged):
    """(veredito, motivo) de [(papel, categoria, motivo, registro)]. COMPLETO só com todos ok; INERTE/PULADO só quando TODOS os papéis são assim;
    qualquer mistura com falha é FALHOU. Em merge o papel pulado (teto do dia, executor ocupado) fica de fora e o resto decide."""
    if mode == "merge" and any(j[1] != "pulado" for j in judged):
        judged = [j for j in judged if j[1] != "pulado"]
    cats = {j[1] for j in judged}
    if cats == {"ok"}:
        return "COMPLETO", "todos os papéis com ao menos %d medidas" % min(j[3]["medidas"] for j in judged)
    by = {}
    for j in judged:
        if j[1] != "ok":
            by.setdefault(j[2], []).append(j[0])
    why = "; ".join("%s: %s" % (",".join(rs), w) for w, rs in by.items())  # papéis com o mesmo motivo dividem uma frase
    return (cats.pop().upper() if len(cats) == 1 else "FALHOU"), why

def render(a, rec):
    items = rec["papeis"].items()
    lines = ["# Bateria de agentes %s (%s) — %s" % (rec["dia"], rec["mode"], rec["verdict"]), "", rec["reason"], ""]
    if items:
        sha = next((r["config_ref_sha"] for _, r in items if r["config_ref_sha"]), None)
        lines += ["- config sob teste: %s do nó @%s · teto %s tokens por papel · mínimo %s medidas por papel · %ss" % (
                  a.config_ref, (sha or "?")[:12], a.night_cap if rec["mode"] == "night" else a.merge_cap, a.min_medidas, rec["wall_s"]), "",
                  "| papel | config_sha | medidas | ok | taxa | estados | tokens | freio |", "|---|---|---|---|---|---|---|---|"]
        dash = lambda x: "-" if x is None else x
        lines += ["| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                  p, (r["config_sha"] or "?")[:12], dash(r["medidas"]), dash(r["ok"]), "-" if r["taxa"] is None else "%.0f%%" % (100 * r["taxa"]),
                  top(r["por_estado"], 5), dash(r["tokens"]), r["freio"] or "-") for p, r in items]
        lines += [""] + ["- %s (%s): %s" % (p, r["cat"], r["motivo"]) for p, r in items if r["cat"] != "ok"]
        if any((r["medidas"] if isinstance(r["medidas"], int) else 0) < 10 for _, r in items):
            lines.append("- amostra pequena (menos de 10 medidas num papel): a taxa dele é ruído; olhe a tendência de várias noites, não uma.")
    return "\n".join(lines) + "\n"

def read_last(path):
    # vazio (arquivo ausente) → None: 1ª sondagem, grava a linha de base e não mede; falhou/ilegível → None também, com aviso: regrava a base e a noite cobre o que passou
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        say("WARN: %s ilegível: regravando a linha de base" % path)
        return None
    return d if isinstance(d, dict) else None

def write_last(path, d):
    try:
        with open(path + ".new", "w", encoding="utf-8") as f:
            json.dump(d, f, sort_keys=True)
        os.replace(path + ".new", path)
    except OSError as e:
        say("WARN: não gravei %s (%s): a próxima sondagem pode repetir esta medida" % (path, e))

def prune(rdir, days):
    # vazio → nada a apagar; falhou ao listar → avisa e não apaga nada (nunca um apagamento às cegas); só relatório .md com mais de `days` dias
    try:
        names = os.listdir(rdir)
    except OSError as e:
        return say("WARN: não consegui listar %s (%s): nada apagado" % (rdir, e))
    for n in names:
        with contextlib.suppress(OSError):
            if n.endswith(".md") and os.path.getmtime(os.path.join(rdir, n)) < time.time() - days * 86400:
                os.unlink(os.path.join(rdir, n))

def finish(a, mode, t0, verdict, why, papeis=None, quiet=None):
    """Veredito → relatório, jsonl, e-mail. A noite deixa rastro em todo veredito e avisa o Mayor em tudo menos PULADO; o merge só fala quando um papel chegou a rodar
    (relatório e jsonl em COMPLETO e FALHOU, e-mail só em FALHOU): INERTE, PULADO e falha antes de rodar de uma sondagem a cada 20 min viram uma linha de stdout; a noite diz o que falta."""
    quiet = (mode == "merge" and verdict in ("PULADO", "INERTE")) if quiet is None else quiet
    day, code = now("%Y-%m-%d"), 1 if verdict == "FALHOU" and not quiet else 0
    rec = {"ts": now(), "mode": mode, "dia": day, "verdict": verdict, "reason": why, "wall_s": int(time.time() - t0), "min_medidas": a.min_medidas,
           "papeis": papeis or {}, "mail_failed": 0}
    if not quiet:
        rdir = os.path.join(a.city, ".gc/logs/agent-battery")
        text = scrub(render(a, rec))
        os.makedirs(rdir, exist_ok=True)
        with open(os.path.join(rdir, "%s.md" % (day if mode == "night" else "%s-merge-%s" % (day, now("%H%M%S")))), "w", encoding="utf-8") as f:
            f.write(text)
        if verdict == "FALHOU" or (mode == "night" and verdict != "PULADO"):
            # vazio → n/a (só o exit importa); falhou (comando ausente ou exit ≠ 0) → mail_failed=1 e o exit vira 1: ninguém acha que o Mayor foi avisado
            if run(shlex.split(a.mail) + ["-s", scrub("[agent-battery] %s %s: %s" % (day, verdict, why)), "-m", text], 120)[0] != 0:
                rec["mail_failed"], code = 1, 1
                say("WARN: e-mail ao Mayor falhou (relatório em %s)" % rdir)
        with open(os.path.join(a.city, ".gc/logs/agent-battery.jsonl"), "a", encoding="utf-8") as f:
            f.write(scrub(json.dumps(rec, ensure_ascii=False, sort_keys=True)) + "\n")
        prune(rdir, a.keep_days)
    say("%s%s: %s" % (verdict, " (silencioso)" if quiet else "", why))
    print("VEREDITO: " + verdict, flush=True)  # a última linha do stdout, sem carimbo: é o que o selftest e quem lê o log procuram
    return code

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("night", "merge"), default="night")
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for name, default, typ in OPTS:
        ap.add_argument("--" + name, type=typ, default=typ(os.environ.get("ABN_" + name.upper().replace("-", "_"), default)))
    a = ap.parse_args()
    roles = [r for r in a.roles.split(",") if r]
    if not roles or any(r not in KNOWN for r in roles) or min(a.night_cap, a.merge_cap, a.min_medidas, a.run_timeout_s, a.keep_days) < 1 or a.limit < 0:
        die(2, "--roles precisa de papéis conhecidos (%s) e os números precisam ser positivos" % ",".join(KNOWN))
    t0 = time.time()
    try:
        return body(a, roles, t0)
    except Exception as e:  # o último recurso: um erro que ninguém previu vira FALHOU com relatório (a sondagem de merge não manda e-mail, mas sai 1)
        return finish(a, a.mode, t0, "FALHOU", "erro inesperado do driver: %s: %s" % (type(e).__name__, e), quiet=a.mode == "merge") or 1

def body(a, roles, t0):
    mode = a.mode
    st = os.path.join(a.city, ".gc/agent-battery")
    os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin")
    pre = lambda v, w: finish(a, mode, t0, v, w, quiet=True if mode == "merge" else None)  # antes de medir, uma sondagem de merge não incomoda ninguém
    os.makedirs(st, exist_ok=True)
    lock = open(os.path.join(st, mode + ".lock"), "w")  # aberto até body() acabar: o flock morre junto com o processo, não há lock velho para limpar
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return pre("PULADO", "outra rodada em andamento (%s)" % lock.name)
    # vazio (sem a bandeira) → PULADO: o nó está desligado por escolha; falhou ao olhar o arquivo → FALHOU, nunca "desligado"
    try:
        os.stat(os.path.join(a.city, ".gc/hetzner-node.on"))
    except FileNotFoundError:
        return pre("PULADO", "nó Linux desligado (falta .gc/hetzner-node.on)")
    except OSError as e:
        return pre("FALHOU", "não consegui olhar a bandeira do nó: %s" % e)
    # vazio (acervo ou .meta.json ausente) → INERTE: a fatia 1 ainda não montou o acervo; falhou ao ler (existe e não lê) → FALHOU, nunca "sem acervo"
    try:
        with open(os.path.join(st, "tasks.jsonl"), "rb") as f:
            tasks = f.read()
        with open(os.path.join(st, "tasks.jsonl.meta.json"), "rb") as f:
            meta = f.read()
    except FileNotFoundError as e:
        return pre("INERTE", "sem acervo de tarefas em %s (rode scripts/agent-battery-corpus.py)" % e.filename)
    except OSError as e:
        return pre("FALHOU", "não consegui ler o acervo: %s" % e)
    for name, data in (("tasks.jsonl", tasks), ("tasks.jsonl.meta.json", meta)):
        if upload(a, name, data)[0] != 0:
            return pre("FALHOU", "não consegui enviar o acervo ao nó %s" % a.node)
    shas, lastp = {}, os.path.join(st, "merge-last.json")
    if mode == "merge":
        shas = probe(a, roles)
        last = read_last(lastp)
        if not shas:
            return pre("PULADO", "não consegui sondar a configuração no nó")
        if last is None:
            write_last(lastp, shas)
            return pre("PULADO", "primeira sondagem: linha de base gravada, nada medido")
        roles = [r for r in roles if r in shas and shas[r] != last.get(r)]
        if not roles:
            return pre("PULADO", "nenhuma configuração mudou desde a última medida")
    # vazio ou falhou (a conta sem item no cofre, o cofre fechado) → INERTE: sem credencial nada roda; o motivo diz o que falta
    why = "ABN_TOKEN_CMD/--token-cmd não definido"
    if a.token_cmd:
        rc, out, err = run(shlex.split(a.token_cmd), 60)
        token = out.strip()
        if rc == 0 and TOKEN_RE.match(token):
            SECRETS.append(token)
            why = ""
        else:
            why = "o comando do token falhou (rc %s) ou não devolveu uma chave: %s" % (rc, first(err, 100))
    if why:
        return pre("INERTE", "sem credencial para o claude do nó: " + why)
    with concurrent.futures.ThreadPoolExecutor(len(roles)) as ex:
        futs = {r: ex.submit(lambda r=r: dict(zip(("rc", "out", "err"), ssh(a, remote_cmd(a, mode, r, False), a.run_timeout_s + 60, (token + "\n").encode())))) for r in roles}
        res = {r: f.result() for r, f in futs.items()}
    judged = [(r,) + judge_safe(a, mode, r, res[r]) for r in roles]
    verdict, why = decide(mode, judged)
    # a configuração que o executor mediu vira a "última": a noite e o merge não repetem uma à outra. Merge que não chegou ao resumo usa a da sondagem (uma mudança é tentada UMA vez); papel pulado não conta como tentado
    last = read_last(lastp) or {}
    last.update({r: rec["config_sha"] or shas.get(r) for r, cat, _, rec in judged if cat != "pulado" and (rec["config_sha"] or shas.get(r))})
    write_last(lastp, last)
    return finish(a, mode, t0, verdict, why, {r: dict(rec, cat=cat, motivo=w) for r, cat, w, rec in judged})

if __name__ == "__main__":
    sys.exit(main())
