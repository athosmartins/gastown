#!/usr/bin/env -S python3 -I
"""hetzner-proof — as medições e a prova de ponta a ponta da fatia 6c (ga-2hd02v.1.5.3): os hooks `keep` no Linux, a latência dos
hooks gc e uma sessão remota mínima. Python 3.9+, só biblioteca padrão. Runbooks: remote-worker-bundle.md, hetzner-hardening.md.

Contents
  Subcomandos · Códigos de saída · Configuração

SUBCOMANDOS
  hooks [--json] [--only IDS]  roda os 6 hooks `keep` com as MESMAS entradas no mini e no servidor e compara código de saída e saída padrão
                            (e, quando o hook bloqueia com 2, a mensagem). Cada caso roda em duas locales (C e en_US.UTF-8: o `grep -i`
                            muda de resposta com a locale, e o provider repassa LANG/LC_*). Caso que não exercita o ramo que diz exercitar
                            (`expect`) reprova a tabela de casos, não o hook.
  latency [--prompts N] [--control M]  N prompts de mentira NO SERVIDOR: a cada um, os hooks de UserPromptSubmit do bundle rodam ao mesmo tempo
                            (o claude os dispara em paralelo) pelo atalho ssh até o mini. Mediana, p95 (posto mais próximo) e máximo por hook e
                            por prompt, o piso do atalho (um pedido que o wrapper recusa: ida e volta sem rodar o gc) e a carga do mini; mais M
                            prompts de CONTROLE com os mesmos hooks direto no mini, sem atalho (separa o custo do atalho do custo do gc).

  e2e [--bead ID] [--model M]  a sessão remota MÍNIMA de ponta a ponta, pelo provider (gc-session-ssh start/peek/stop), com o pedido que o engine
                            mandaria: worktree no servidor (espelho), pasta pré-confiada, `remote-e2e-1` lê uma bead, comenta, comita, empurra pelo
                            espelho, pede o handoff e termina; depois confere CADA prova por fora (comentário na bead, commit no servidor, branch no
                            origin com o mesmo sha, mail do handoff, hooks de filtro/log rodando, sessão parada). Nunca responde a diálogo desconhecido.

CÓDIGOS  0 tudo igual / medido · 1 diferença, caso mal escrito ou hook que falhou · 2 uso · 3 não consegui rodar/ler um dos lados (nunca vira "igual")
CONFIGURAÇÃO (ambiente)  HETZNER_SSH_HOST (hetzner-teste) · HETZNER_PROOF_ALIAS (remote-e2e-1: a identidade que o wrapper do mini aceita)
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shlex
import subprocess
import sys
import time

HOST = os.environ.get("HETZNER_SSH_HOST", "hetzner-teste")
ALIAS = os.environ.get("HETZNER_PROOF_ALIAS", "remote-e2e-1")
LOCALES = ("C", "en_US.UTF-8")
HOOKS_REMOTE = "~/.claude/hooks"
BUNDLE_SETTINGS = "~/gt-remote/bundle/city/settings.json"


def sh_remote(prog: str, stdin: str = "", timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, prog],
                          input=stdin.encode(), capture_output=True, timeout=timeout)


# ---------------------------------------------------------------- hooks
# O programa abaixo roda DE VERDADE nos dois lados (python3 -I - com o texto na entrada padrão): o mesmo código, as mesmas entradas.
RUNNER = r'''
import hashlib, json, os, re, shutil, subprocess, tempfile
HOOKS = os.path.expanduser(%r)
def norm(s, t):
    s = s.replace(t, "$T")
    return re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "<ts>", s)
def one(c, loc):
    t = tempfile.mkdtemp(prefix="hproof-")
    try:
        os.makedirs(t + "/.claude/hooks")
        if "transcript" in c:
            with open(t + "/t.jsonl", "w") as f:
                f.write("\n".join(c["transcript"]) + "\n")
        env = {"PATH": os.environ["PATH"], "HOME": t, "LC_ALL": loc, "LANG": loc}
        env.update(c.get("env", {}))
        try:
            p = subprocess.run([HOOKS + "/" + c["hook"]], input=c["stdin"].replace("{T}", t).encode(), capture_output=True, env=env, cwd=t, timeout=60)
        except Exception as e:
            return {"fail": "%%s: %%s" %% (type(e).__name__, e)}
        log = ""
        for root, _, names in os.walk(t + "/.claude"):
            for n in sorted(names):
                if n.endswith((".log", ".jsonl")):
                    log += n + ": " + open(os.path.join(root, n), errors="replace").read()
        return {"rc": p.returncode, "out": norm(p.stdout.decode("utf-8", "replace"), t), "err": norm(p.stderr.decode("utf-8", "replace"), t), "log": norm(log, t)}
    finally:
        shutil.rmtree(t, ignore_errors=True)
def tool(n):
    w = shutil.which(n)
    if not w:
        return None
    try:
        v = subprocess.run([w, "--version"], capture_output=True, timeout=10).stdout.decode("utf-8", "replace").splitlines()
    except Exception:
        v = []
    return w + " :: " + (v[0] if v else "?")
def main(cases, locales):
    hs = {}
    for c in cases:
        h = c["hook"]
        if h not in hs:
            try:
                hs[h] = hashlib.sha256(open(HOOKS + "/" + h, "rb").read()).hexdigest()
            except OSError as e:
                hs[h] = None
    print(json.dumps({"tools": {n: tool(n) for n in ("grep", "jq", "python3", "awk", "bash", "cut", "date")}, "hashes": hs,
                      "results": {c["id"] + "|" + l: (one(c, l) if hs[c["hook"]] else {"fail": "hook ausente"}) for c in cases for l in locales}}))
main(json.loads(%r), json.loads(%r))
'''


def _tr(text: str, tool: str = "") -> list:
    """Transcrição mínima (JSONL compacto, como o claude grava): uma fala do usuário e a resposta do assistente."""
    ass = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}] +
                                            ([{"type": "tool_use", "id": "x", "name": tool, "input": {}}] if tool else [])}}
    return ['{"type":"user","message":{"role":"user","content":"oi"}}', json.dumps(ass, ensure_ascii=False, separators=(",", ":"))]


def _bash(cmd: str) -> str:
    return json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}, ensure_ascii=False)


STOP, MAIL = "enforce-multiple-choice-question.sh", "enforce-mail-mcq-on-send.sh"
FB, FT, FS, LOGT = "filter-bash-output.sh", "filter-test-output.sh", "filter-scraper-output.sh", "log-token-usage.sh"


def _stop(i: str, what: str, text: str, tool: str = "", expect: int = None, env: dict = None, **kw) -> dict:
    c = dict(id=i, what=what, hook=STOP, transcript=_tr(text, tool), stdin=json.dumps({"transcript_path": "{T}/t.jsonl", **kw}), expect=expect)
    return dict(c, env=env) if env else c


def _case(i: str, what: str, hook: str, stdin: str, expect: int = None, has: str = "") -> dict:
    return dict(id=i, what=what, hook=hook, stdin=stdin, expect=expect, has=has)


Q = "Terminei a migração.\nVocê prefere A ou B?"
CASES = [
    _case("s01", "stdin vazio", STOP, "", 0),
    _case("s02", "stdin que não é JSON", STOP, "lixo", 0),
    _case("s03", "transcript que não existe", STOP, json.dumps({"transcript_path": "{T}/nada.jsonl"}), 0),
    _stop("s04", "pergunta aberta ao Athos (acento)", Q, expect=2),
    _stop("s05", "pergunta aberta, ASCII", "Terminei.\nVoce prefere A ou B?", expect=2),
    _stop("s06", "AskUserQuestion no turno", Q, tool="AskUserQuestion", expect=0),
    _stop("s07", "stop_hook_active (anti-laço)", Q, expect=0, stop_hook_active=True),
    _stop("s08", "retórica auto-respondida (? Porque)", "Você quer que eu siga? Porque já fiz o resto.", expect=0),
    _stop("s09", "retórica com maiúscula acentuada (? NÃO)", "Você prefere A? NÃO, é B.", expect=None),
    _stop("s10", "dog headless (GC_AGENT) é isento", Q, env={"GC_AGENT": "gastown.dog-1"}, expect=0),
    _stop("s11", "'?' fora das 3 últimas linhas", "Você prefere A?\nx\ny\nz", expect=0),
    _case("m01", "stdin vazio", MAIL, "", 0),
    _case("m02", "outra ferramenta", MAIL, json.dumps({"tool_name": "Read", "tool_input": {"command": "gc mail send human -m 'Você prefere?'"}}), 0, "{}"),
    _case("m03", "Bash que não é mail send", MAIL, _bash("echo oi"), 0, "{}"),
    _case("m04", "pergunta aberta ao human", MAIL, _bash('gc mail send human -s x -m "Resumo.\nVocê prefere A ou B?"'), 0, "deny"),
    _case("m05", "opções numeradas passam", MAIL, _bash('gc mail send human -s x -m "Contexto.\n1) A\n2) B\nQual opção?"'), 0, "{}"),
    _case("m06", "pergunta a outro agente passa", MAIL, _bash('gc mail send gastown.mayor -m "Você prefere A ou B?"'), 0, "{}"),
    _case("m07", "corpo em heredoc", MAIL, _bash("gc mail send human -s x -m \"$(cat <<'EOF'\nSegue.\nVocê quer que eu siga?\nEOF\n)\""), 0, "deny"),
    _case("m08", "2º segmento é o do human", MAIL, _bash('gc mail send a -m "oi" && gc mail send human -m "Você quer que eu siga?"'), 0, "deny"),
    _case("m09", "pergunta relatada passa", MAIL, _bash('gc mail send human -m "Fulano perguntou se você quer isso? Já resolvi."'), 0, "{}"),
    _case("m10", "maiúsculas acentuadas", MAIL, _bash('gc mail send human -m "VOCÊ QUER QUE EU SIGA?"'), 0, "deny"),
    _case("m11", "retórica com ? NÃO", MAIL, _bash('gc mail send human -m "Você quer que eu siga? NÃO, já fiz."'), 0, ""),
    _case("m12", "stdin que não é JSON", MAIL, "lixo", 0, "{}"),
    _case("f01", "filter-bash: git log", FB, _bash("git log --oneline"), 0, "head -n 100"),
    _case("f02", "filter-bash: comando comum", FB, _bash("echo hi"), 0, "{}"),
    _case("f03", "filter-bash: aspas, quebra de linha e acento", FB, _bash('git diff -- "a b" \'c\'\n# ação'), 0, "head -n 100"),
    _case("f04", "filter-bash: stdin que não é JSON", FB, "lixo", 0, "{}"),
    _case("t01", "filter-test: pytest", FT, _bash("pytest -x tests/"), 0, "grep -A 10"),
    _case("t02", "filter-test: ls", FT, _bash("ls"), 0, "{}"),
    _case("c01", "filter-scraper: scraper", FS, _bash("python3 scrapers/foo_scraper.py --x"), 0, "grep -E"),
    _case("c02", "filter-scraper: python -c", FS, _bash("python3 -c 1"), 0, "{}"),
    _case("l01", "log-token-usage: string com acento", LOGT, json.dumps({"tool_name": "Bash", "tool_output": "ação 日本 ok"}, ensure_ascii=False), 0, "{}"),
    _case("l02", "log-token-usage: saída que é objeto", LOGT, json.dumps({"tool_name": "Read", "tool_output": {"a": 1, "b": 2}}), 0, "{}"),
    _case("l03", "log-token-usage: stdin que não é JSON", LOGT, "lixo", 0, "{}"),
]


def run_side(label: str, remote: bool, cases: list) -> dict:
    prog = RUNNER % (HOOKS_REMOTE, json.dumps(cases, ensure_ascii=False), json.dumps(list(LOCALES)))
    try:
        if remote:
            p = sh_remote("python3 -I -", prog)
        else:
            p = subprocess.run([sys.executable, "-I", "-"], input=prog.encode(), capture_output=True, timeout=600)
        data = json.loads(p.stdout.decode("utf-8"))
        if p.returncode != 0 or not isinstance(data.get("results"), dict):
            raise ValueError(f"rc={p.returncode}")
        return data
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:  # não consegui rodar/ler: o lado fica sem resultado (nunca "igual")
        return {"error": f"{label}: {type(e).__name__}: {e}"}


def judge(a: dict, b: dict, case: dict) -> tuple:
    """(veredito, nota). IGUAL só se os dois lados RODARAM e concordam no código e na saída (e na mensagem, quando o código é 2)."""
    if "fail" in a or "fail" in b or "rc" not in a or "rc" not in b:
        return "NAO-RODOU", " | ".join(x["fail"] for x in (a, b) if "fail" in x)[:120]
    if a["rc"] != b["rc"] or a["out"] != b["out"] or (a["rc"] == 2 and a["err"] != b["err"]):
        return "DIFERENTE", f"rc {a['rc']}/{b['rc']}"
    notes = [n for n, k in (("stderr", "err"), ("log", "log")) if a[k] != b[k]]
    return "IGUAL", ("só difere em " + ",".join(notes)) if notes else ""


def cmd_hooks(args: argparse.Namespace) -> int:
    cases = [c for c in CASES if not args.only or c["id"] in args.only.split(",")]
    if not cases:
        print("--only não casa nenhum caso", file=sys.stderr)
        return 2
    mini, srv = run_side("mini", False, cases), run_side("servidor", True, cases)
    if "error" in mini or "error" in srv:
        print("NAO CONSEGUI RODAR:", mini.get("error") or "", srv.get("error") or "", file=sys.stderr)
        return 3
    rows, bad, notrun = [], 0, 0
    same_files = all(mini["hashes"][h] is not None and mini["hashes"][h] == srv["hashes"][h] for h in mini["hashes"])
    for c in cases:
        for loc in LOCALES:
            k = c["id"] + "|" + loc
            v, note = judge(mini["results"][k], srv["results"][k], c)
            m = mini["results"][k]
            if v == "IGUAL" and c["expect"] is not None and m.get("rc") != c["expect"] and loc == "en_US.UTF-8":
                v, note = "CASO-RUIM", f"esperava rc {c['expect']}, deu {m.get('rc')} nos dois lados"
            if v == "IGUAL" and c.get("has") and c["has"] not in (m.get("out", "") + m.get("err", "")) and loc == "en_US.UTF-8":
                v, note = "CASO-RUIM", f"saída sem {c['has']!r} nos dois lados"
            bad += v in ("DIFERENTE", "CASO-RUIM")
            notrun += v == "NAO-RODOU"
            rows.append((c["hook"], c["id"], c["what"], loc, m.get("rc", "-"), srv["results"][k].get("rc", "-"), v, note))
    if args.json:
        print(json.dumps({"hooks_identicos": same_files, "mini": mini["tools"], "servidor": srv["tools"], "linhas": rows}, ensure_ascii=False, indent=1))
    else:
        print(f"{'hook':35} {'caso':4} {'locale':11} {'mini':>4} {'serv':>4}  veredito   caso/nota")
        for h, i, what, loc, a, b, v, note in rows:
            print(f"{h[:-3]:35} {i:4} {loc:11} {a!s:>4} {b!s:>4}  {v:10} {what}{' — ' + note if note else ''}")
        for n in sorted(mini["tools"]):
            print(f"ferramenta {n:8} mini: {mini['tools'][n]}\n{'':20} servidor: {srv['tools'][n]}")
        print(f"hooks idênticos nos dois lados (sha256): {'sim' if same_files else 'NÃO'}")
        print(f"{len(rows)} execuções: {sum(r[6] == 'IGUAL' for r in rows)} iguais, {bad} diferentes/mal escritas, {notrun} não rodaram")
    if not same_files:
        print("NAO-COMPARAVEL: algum arquivo de hook falta ou difere entre o mini e o servidor (rode push-bundle)", file=sys.stderr)
        return 3
    return 3 if notrun else (1 if bad else 0)


# ---------------------------------------------------------------- latency
LAT = r'''
import json, os, signal, subprocess, sys, time
C = json.loads(%r)
# vazio (settings sem hook de UserPromptSubmit) → `hooks` vazio e o driver recusa medir; falhou/ilegível (arquivo ausente, JSON ruim) → o programa cai e o driver diz NAO CONSEGUI MEDIR
cmds = [h["command"] for g in json.load(open(os.path.expanduser(C["settings"])))["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
# remoto: o ambiente da sessão (tmux) + a identidade; controle local: o que o wrapper do mini monta para o gc (HOME, USER, PATH, identidade; nada mais)
env = dict(os.environ, **C["env"]) if not C["clean"] else dict(C["env"], HOME=os.environ["HOME"], USER=os.environ.get("USER", ""), PATH=C["path"])
def launch(argv):  # sessão nova por processo: no estouro do prazo mata o GRUPO (o `sh -c … && gc` deixaria o gc para trás)
    return subprocess.Popen(argv, env=env, cwd=C["cwd"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
def run(argvs):
    """Dispara TODOS juntos e mede cada um desde o MESMO t0 (esperar um a um inflava o mais rápido até o fim do mais lento); a parede é o relógio de t0 até o último."""
    t0 = time.monotonic()
    ps = [launch(a) for a in argvs]
    res = [None] * len(ps)
    while None in res:
        for k, p in enumerate(ps):
            if res[k] is None:
                rc = p.poll()
                if rc is None and time.monotonic() - t0 > C["tmo"]:
                    os.killpg(p.pid, signal.SIGKILL); p.wait(); rc = "timeout"
                if rc is not None:
                    res[k] = {"s": round(time.monotonic() - t0, 3), "rc": rc}
        time.sleep(0.02)
    return res, round(time.monotonic() - t0, 3)
print(json.dumps({"hooks": cmds}), flush=True)
for i in range(C["n"]):
    hs, wall = run([["sh", "-c", c] for c in cmds])
    row = {"i": i, "wall": wall, "hooks": hs}
    if C["floor"]:  # pedido que o wrapper do mini RECUSA (gc prime sem --hook): a ida e volta do atalho sem rodar o gc
        row["floor"] = run([["sh", "-c", 'export PATH="$HOME/.local/bin:$PATH"; gc prime']])[0][0]
    print(json.dumps(row), flush=True)
'''


def pct(xs: list, p: float) -> float:
    s = sorted(xs)
    return s[max(0, math.ceil(p * len(s)) - 1)]  # posto mais próximo: p95 de 20 amostras é a 19ª


def lat_rows(argv: list, cfg: dict, label: str) -> tuple:
    """Roda o programa LAT (aqui ou no servidor) e devolve (hooks, linhas); cada linha leva a carga do mini no instante em que chegou."""
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.stdin.write((LAT % json.dumps(cfg)).encode())
    p.stdin.close()
    rows, hooks = [], []
    for line in p.stdout:
        try:  # vazio → menos linhas que o pedido e a medição recusa (OSError abaixo); linha que não é JSON (banner do ssh) é pulada, nunca vira amostra
            r = json.loads(line)
        except ValueError:
            continue
        if "i" not in r:
            hooks = r["hooks"]
            continue
        r["load"] = round(os.getloadavg()[0], 1)
        rows.append(r)
        print(f"{label} {r['i']:3} parede {r['wall']:7.2f}s  hooks {[h['s'] for h in r['hooks']]}  rc {[h['rc'] for h in r['hooks']]}"
              + (f"  piso {r['floor']['s']}s" if "floor" in r else "") + f"  carga do mini {r['load']}", flush=True)
    p.wait()
    if len(rows) < cfg["n"] or not hooks:
        raise OSError(f"{label}: {len(rows)} de {cfg['n']} prompts ({p.stderr.read().decode('utf-8', 'replace').strip()[:300]})")
    return hooks, rows


def table(title: str, hooks: list, rows: list) -> list:
    cols = {"prompt (parede, em paralelo)": [r["wall"] for r in rows], "soma dos hooks (em fila)": [sum(h["s"] for h in r["hooks"]) for r in rows]}
    if "floor" in rows[0]:
        cols["piso do atalho (pedido recusado)"] = [r["floor"]["s"] for r in rows]
    for j, c in enumerate(hooks):
        cols[f"hook {j}: {c.split('&& ', 1)[-1]}"] = [r["hooks"][j]["s"] for r in rows]
    loads = [r["load"] for r in rows]
    print(f"\n{title}: {len(rows)} prompts · carga do mini (1 min) mín {min(loads)}, máx {max(loads)}\n{'medida':62} {'mediana':>8} {'p95':>8} {'máx':>8}")
    for k, xs in cols.items():
        print(f"{k:62} {pct(xs, .5):8.2f} {pct(xs, .95):8.2f} {max(xs):8.2f}")
    return [(r["i"], j, h["rc"]) for r in rows for j, h in enumerate(r["hooks"]) if h["rc"] != 0]


def cmd_latency(args: argparse.Namespace) -> int:
    ident = {k: ALIAS for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE")}
    base = {"n": args.prompts, "tmo": args.timeout, "env": ident, "settings": BUNDLE_SETTINGS, "clean": False, "floor": True, "cwd": "/", "path": ""}
    city = os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    try:
        hooks, rows = lat_rows(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, "python3 -I -"], base, "servidor")
        fails = table("servidor (atalho ssh → mini)", hooks, rows)
        if args.control:  # o MESMO par de hooks, direto no mini, sem atalho: separa o custo do atalho do custo do gc sob a carga do mini
            ctl = dict(base, n=args.control, clean=True, floor=False, settings=f"{city}/.gc/settings.json", cwd=city,
                       path=os.environ["PATH"], env=dict(ident, GC_CITY=city))
            h2, r2 = lat_rows([sys.executable, "-I", "-"], ctl, "controle ")
            fails += table("controle (mesmos hooks direto no mini, sem atalho)", h2, r2)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"NAO CONSEGUI MEDIR: {e}", file=sys.stderr)
        return 3
    print(f"hooks com saída ≠ 0 ou timeout: {len(fails)} {fails[:6]}")
    return 1 if fails else 0


# ---------------------------------------------------------------- e2e
HERE = os.path.dirname(os.path.realpath(__file__))
CITY = os.environ.get("GC_CITY_PATH") or os.path.dirname(HERE)  # a cidade VIVA (estado, config do provider); o código pode vir de um worktree
PROV = os.environ.get("HETZNER_PROOF_PROV") or os.path.join(HERE, "gc-session-ssh")  # (só o selftest troca o provider e o gate)
GATE = os.environ.get("HETZNER_PROOF_GATE") or os.path.join(HERE, "hetzner-claude.py")
RHOME = os.environ.get("HETZNER_REMOTE_HOME", "/home/runner")
POLL = float(os.environ.get("HETZNER_PROOF_POLL", "10"))  # segundos entre uma olhada e outra na tela e na espera pelo origin (só o selftest baixa)
MARK = "E2E-42-OK"  # o prompt só traz `E2E-$((6*7))-OK`: ver este texto na tela quer dizer que o comando RODOU, não que o prompt foi ecoado
DIALOGS = ("trust this folder", "Yes, I trust", "Bypass Permissions", "Enter to confirm", "Choose the text style", "Security notes", "Do you want to proceed")
PROMPT = """This is a minimal end-to-end check of a remote worker. Do exactly the steps below, one Bash call each, in order. Do not ask questions, \
do not edit any other file. If a step fails, still run the remaining steps, then finish with: FAILED step <n>.
1. bd show {bead} --json
2. bd comment {bead} "{name}: sessao remota minima {run} leu esta bead"
3. mkdir -p e2e && echo "remote-e2e {run}" > e2e/{run}.txt && git add e2e/{run}.txt && git commit -m "chore(remote-e2e): {run} (sem dado, descartavel)"
4. git log --oneline -3
5. git push origin HEAD
6. gc handoff --auto "context cycle"
7. echo E2E-$((6*7))-OK
"""
HOOKLOG = r"""import glob, json, os, sys
rows, bad = [], 0  # vazio (nenhuma transcrição) → [] e as provas reprovam; linha ilegível → CONTADA e a prova dos hooks reprova (uma linha perdida pode ser o hook que falhou)
for f in glob.glob(os.path.expanduser("~/.claude/projects/*%s*/*.jsonl") % sys.argv[1]):
    for line in open(f, errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            bad += 1
            continue
        a = o.get("attachment") or {}
        if str(a.get("type", "")).startswith("hook_") and a.get("hookEvent") and a.get("command"):
            rows.append({"event": a["hookEvent"], "cmd": a["command"], "ms": a.get("durationMs"), "rc": a.get("exitCode"), "kind": a["type"],
                         "timeout": a.get("timeoutMs") if a.get("timedOut") else None})
        if o.get("type") == "system" and o.get("subtype") == "stop_hook_summary":  # hook de Stop não deixa attachment: o resumo diz o que rodou e se deu erro
            rows += [{"event": "Stop", "cmd": h.get("command", ""), "ms": h.get("durationMs"), "rc": 1 if o.get("hookErrors") else 0, "kind": "hook_success", "timeout": None} for h in o.get("hookInfos") or []]
print(json.dumps({"rows": rows, "unreadable": bad}))
"""
PREPARE = r"""set -e
R=$HOME/gt-remote/git/gascity; W=$R/wt/$1
$HOME/gt-remote/bin/hetzner-remote-git.sh wt-add gascity "$1"
if [ "$(git -C "$R/repo.git" config --get extensions.worktreeConfig)" != true ]; then  # o sparse-checkout do wt-add já liga isto direito; ligado à mão num repo BARE, o core.bare compartilhado quebra o commit em todo worktree
  git -C "$R/repo.git" config extensions.worktreeConfig true
  git -C "$R/repo.git" config --worktree core.bare true && git -C "$R/repo.git" config --unset core.bare
fi
git -C "$W" config --worktree user.name "$2"
git -C "$W" config --worktree user.email "$2@gastown.invalid"
python3 -I - "$W" <<'PY'
import json, os, sys, tempfile
p = os.path.expanduser("~/.claude.json")
d = json.load(open(p))  # ilegível: o erro derruba o passo e NADA é gravado
pr = d.setdefault("projects", {}).setdefault(sys.argv[1], {})
pr.update(hasTrustDialogAccepted=True, hasCompletedProjectOnboarding=True)
pr.setdefault("allowedTools", [])
fd, t = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f)
os.chmod(t, os.stat(p).st_mode & 0o777)
os.replace(t, p)
PY
echo "HEAD $(git -C "$W" rev-parse HEAD)"
echo "ANALYTICS $(wc -l < $HOME/.claude/usage-analytics.jsonl 2>/dev/null || echo 0)"
"""
IDENT = " ".join(f"{k}={ALIAS}" for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE"))


class E2E:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a, self.checks = a, []
        self.run = "remote-e2e-" + time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        self.wt = f"{RHOME}/gt-remote/git/gascity/wt/{self.run}"
        path = a.log or f"{CITY}/.gc/logs/hetzner-e2e-{self.run}.log"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.f = open(path, "a")
        self.env = dict(os.environ, GC_SSH_CONFIG=os.environ.get("GC_SSH_CONFIG") or f"{CITY}/.gc/session-ssh.json",
                        GC_EXEC_STATE_DIR=os.environ.get("GC_EXEC_STATE_DIR") or f"{CITY}/.gc/runtime/session-ssh", HETZNER_STATE_DIR=f"{CITY}/.gc")
        self.started, self.mail = False, []
        self.t0 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.say(f"e2e {self.run} · log {path} · carga do mini {os.getloadavg()[0]:.1f}")

    def say(self, msg: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.checks.append((name, ok))
        self.say(f"{'PASS' if ok else 'FAIL'} {name}{' — ' + detail if detail else ''}")
        return ok

    def prov(self, *args: str, stdin: str = "", timeout: int = 180) -> subprocess.CompletedProcess:
        return subprocess.run([PROV, *args], input=stdin.encode(), capture_output=True, timeout=timeout, env=self.env)

    def out(self, p: subprocess.CompletedProcess) -> str:
        return (p.stdout + p.stderr).decode("utf-8", "replace").strip()

    def ssh(self, script: str, timeout: int = 600) -> tuple:
        # o script vai para um arquivo e roda com a entrada em /dev/null: com `bash -s` qualquer filho que leia a entrada (o ssh do pull) engoliria o resto do script
        p = sh_remote('f=$(mktemp) || exit 125; cat >"$f"; bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc', script, timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    def preconditions(self) -> bool:
        g = subprocess.run([sys.executable, "-I", GATE, "gate"], capture_output=True, env=self.env)
        self.say(f"login do claude no servidor (gate): rc {g.returncode} {self.out(g)[:200]}")
        rc, o, e = self.ssh(f'export PATH="$HOME/.local/bin:$PATH"; env {IDENT} bd show {self.a.bead} --json | head -c 300')
        self.say(f"atalho bd (servidor → mini) com a identidade {ALIAS}: rc {rc} {(o or e)[:120]!r}")
        left = self.out(self.prov("list-running", "remote-e2e"))
        if ALIAS in left.split():  # sobra de uma rodada anterior: o nome é reservado a esta prova
            self.say(f"sobrou a sessão {ALIAS}: parando")
            self.prov("stop", ALIAS)
        return g.returncode == 0 and rc == 0 and '"id"' in o

    def prepare(self) -> bool:
        rc, o, e = self.ssh(PREPARE.replace("$1", self.run).replace("$2", ALIAS))
        self.say(f"worktree + identidade git + pasta pré-confiada: rc {rc}\n{(o + e).strip()[-600:]}")
        # vazio/ilegível (sem a linha HEAD ou ANALYTICS) → None e o passo devolve False: nada começa; nunca "0 linhas" por omissão
        m = re.search(r"^HEAD (\w+)$", o, re.M)
        n = re.search(r"^ANALYTICS\s+(\d+)$", o, re.M)
        self.head0, self.analytics0 = m and m.group(1), n and int(n.group(1))
        return rc == 0 and bool(m) and bool(n) and '"pull":"ok"' in o

    def start(self) -> bool:
        city = CITY
        # a ORDEM é a do engine para o pool (medido 17/10: com o arquivo da cidade ANTES do --settings inline os hooks `gc` do city não carregaram — o claude só vale o último)
        cmd = (f"{city}/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh --settings '{{\"remoteControlAtStartup\":false}}' --model {self.a.model} "
               f"--strict-mcp-config --dangerously-skip-permissions --settings {city}/.gc/settings.json")
        env = {k: ALIAS for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE")}
        env.update(GC_SESSION_ORIGIN="ephemeral", GC_CITY=city, GC_CITY_PATH=city, LANG="en_US.UTF-8", TERM="xterm-256color")
        req = {"command": cmd, "work_dir": self.wt, "env": env, "prompt_flag": "",
               "prompt_suffix": shlex.quote(PROMPT.format(bead=self.a.bead, name=ALIAS, run=self.run))}
        p = self.prov("start", ALIAS, stdin=json.dumps(req), timeout=120)
        self.started = p.returncode == 0 or "already exists" in self.out(p)
        return self.check("start pelo provider", p.returncode == 0, self.out(p)[:300])

    def watch(self) -> str:
        """Espera o MARK na tela. Diálogo desconhecido ou sessão que morre antes = falha com a tela; nunca responde por conta própria."""
        end, seen = time.time() + self.a.timeout, ""
        while time.time() < end:
            time.sleep(POLL)
            seen = self.out(self.prov("peek", ALIAS, "250"))
            if MARK in seen:
                return seen
            if any(d in seen for d in DIALOGS):
                self.check("sessão andou sem diálogo de primeira execução", False, "tela:\n" + seen[-1200:])
                return seen
            run = self.out(self.prov("is-running", ALIAS))
            if run != "true":
                self.check("sessão ficou de pé até o fim", False, f"is-running={run!r}; tela:\n{seen[-1200:]}")
                return seen
        self.check("sessão terminou os 7 passos no prazo", False, f"{self.a.timeout}s; tela:\n{seen[-1200:]}")
        return seen

    def evidence(self) -> None:
        a = self.a
        # vazio/ilegível ou rc ≠ 0 → o comentário da rodada não aparece e a prova reprova (com o rc); estouro do prazo → exceção, que o go() registra como prova que reprova
        c = subprocess.run(["bd", "comments", a.bead, "--json"], capture_output=True, cwd=CITY, timeout=180)
        txt = c.stdout.decode("utf-8", "replace")
        self.check("comentário da sessão na bead", c.returncode == 0 and self.run in txt, f"bd comments rc {c.returncode}")
        # vazio/ssh que falhou → sha "" e as provas do commit e da branch reprovam (nunca "igual" por falta de dado)
        rc, o, e = self.ssh(f"git -C {self.wt} log -1 --format='%H|%an|%s'; echo ANALYTICS $(wc -l < $HOME/.claude/usage-analytics.jsonl 2>/dev/null || echo 0)")
        sha = (re.match(r"^(\w{40})\|", o) or [None, ""])[1]
        self.check("commit no worktree do servidor, com a identidade da sessão", bool(sha) and sha != self.head0 and f"|{ALIAS}|" in o and self.run in o, o.splitlines()[0] if o else e[:200])
        url = subprocess.run(["git", "-C", f"{CITY}/.gc/hetzner-mirror/repos/gascity.git", "config", "remote.origin.url"], capture_output=True).stdout.decode().strip()
        got = ""  # vazio (a branch ainda não chegou) → espera até o fim das olhadas e reprova "sem a branch"; falhou o ls-remote → got "" e o mesmo; estouro do prazo → exceção, vide acima
        for _ in range(18):  # o espelho publica em segundo plano: até 18 olhadas (~3 min com o POLL padrão)
            r = subprocess.run(["git", "ls-remote", url, f"refs/heads/worker/{self.run}"], capture_output=True, timeout=60)
            got = r.stdout.decode().split("\t")[0]
            if got:
                break
            time.sleep(POLL)
        self.check("a branch chegou ao origin, com o mesmo sha do servidor", bool(sha) and got == sha, f"origin {got[:12] or 'sem a branch'} · servidor {sha[:12]}")
        # o mail é um wisp (efêmero): `bd list` NÃO o mostra (medido 17/10: voltou []), só `bd query ephemeral=true`
        mm = subprocess.run(["bd", "query", "--json", f"ephemeral=true AND assignee={ALIAS}", "--limit=0"], capture_output=True, cwd=CITY, timeout=180)
        try:  # vazio → nenhuma mensagem desta rodada (reprova); ilegível/falhou → reprova dizendo que NÃO consegui ler (não é "vazio")
            msgs = [x for x in json.loads(mm.stdout) if x.get("title") == "context cycle" and "gc:auto-handoff" in (x.get("labels") or [])
                    and x.get("created_at", "") >= self.t0] if mm.returncode == 0 else None
        except ValueError:
            msgs = None
        self.mail = [x["id"] for x in msgs or []]
        self.check("handoff registrado no mini (mail do handoff para a sessão)", bool(msgs), f"{self.mail}" if msgs is not None else f"não consegui ler: bd query rc {mm.returncode}")
        n = re.search(r"ANALYTICS\s+(\d+)", o)
        self.check("hook de log (PostToolUse) rodou no servidor", bool(n) and self.analytics0 is not None and int(n.group(1)) > self.analytics0, f"{self.analytics0} → {n and n.group(1)} linhas")
        rc, o, e = self.ssh(f"python3 -I - {self.run} <<'PY'\n{HOOKLOG}\nPY")
        try:  # a transcrição da sessão REAL é a prova de que o claude carregou o --settings do city e disparou os hooks (não a fixture do selftest)
            doc = json.loads(o) if rc == 0 else None
            rows, unreadable = doc["rows"], doc["unreadable"]
        except (ValueError, KeyError, TypeError):
            rows = None
        if rows is None:
            self.check("hooks da sessão real lidos na transcrição", False, f"não consegui ler: rc {rc} {e[:120]}")
            return
        gc = [r for r in rows if " gc " in r["cmd"]]
        prime = [r for r in gc if r["event"] == "SessionStart" and "gc prime" in r["cmd"] and r["kind"] == "hook_success" and r["rc"] == 0]
        ups = [r for r in gc if r["event"] == "UserPromptSubmit"]
        ms = lambda xs: [r["ms"] for r in xs]
        out = lambda r: f"cancelado pelo prazo de {r['timeout']} ms" if r["timeout"] else "ok" if r["kind"] == "hook_success" and r["rc"] == 0 else f"FALHOU ({r['kind']}, saída {r['rc']})"
        slow = [r for r in gc if r["timeout"]]
        # hook que não imprime nada não deixa registro na transcrição (o `mail check` de um alias sem caixa): exige o prime e o drain; cada registro tem de ser "ok" ou "cancelado pelo
        # prazo do claude" (resultado medido, dito à parte); qualquer outra coisa (saída ≠ 0, erro) reprova
        self.check("hooks gc do city carregaram e dispararam na sessão real (SessionStart prime ok + UserPromptSubmit drain)",
                   bool(prime) and any("nudge drain" in r["cmd"] for r in ups) and all(out(r) == "ok" or r["timeout"] for r in gc),
                   f"prime {ms(prime)} ms · " + " · ".join(f"{r['cmd'].split('gc ', 1)[-1]}: {r['ms']} ms {out(r)}" for r in ups))
        if slow:
            self.say(f"ATENÇÃO: {len(slow)} hook(s) gc CANCELADO(s) pelo prazo do claude ({slow[0]['timeout']} ms) — o resultado deles foi descartado nesse prompt; ver a latência em hetzner-hardening.md")
        keep = [r for r in rows if ".claude/hooks/" in r["cmd"]]
        self.check("hooks keep rodaram na sessão real, todos com saída 0, transcrição toda legível", bool(keep) and all(r["kind"] == "hook_success" and r["rc"] == 0 for r in keep) and unreadable == 0,
                   f"{len(keep)} execuções, {min(ms(keep), default=0)}–{max(ms(keep), default=0)} ms, {unreadable} linhas ilegíveis")

    def finish(self) -> None:
        if self.started:
            try:  # falhou/estourou: a sessão pode seguir aberta → a prova reprova com o motivo (nunca "parada" por omissão)
                p = self.prov("stop", ALIAS)
                lst = self.out(self.prov("list-running", "remote-e2e"))
                self.check("sessão parada pelo provider e fora da lista", p.returncode == 0 and ALIAS not in lst.split(), self.out(p)[:200] or lst[:120])
            except (OSError, subprocess.SubprocessError) as e:
                self.check("sessão parada pelo provider e fora da lista", False, f"não consegui parar/conferir: {type(e).__name__}: {e}")
        for mid in self.mail:  # o mail de teste fica aberto (uma sessão que ninguém registrou nunca o injeta): arquivar é o que o `gc mail archive` faz
            try:
                a = subprocess.run(["gc", "mail", "archive", mid], capture_output=True, cwd=CITY, timeout=180)
                self.say(f"mail de teste {mid} arquivado: rc {a.returncode}")
            except (OSError, subprocess.SubprocessError) as e:
                self.say(f"mail de teste {mid} NÃO arquivado ({type(e).__name__}): arquive à mão com `gc mail archive {mid}`")
        if not self.a.keep:
            try:
                rc, o, e = self.ssh(f"$HOME/gt-remote/bin/hetzner-remote-git.sh wt-rm gascity {self.run}")
                self.say(f"worktree removido: rc {rc} {(o or e).strip()[:120]}")
            except (OSError, subprocess.SubprocessError) as e:
                self.say(f"worktree {self.run} NÃO removido ({type(e).__name__}): `hetzner-remote-git.sh wt-rm gascity {self.run}` no servidor")

    def go(self) -> int:
        try:
            if not self.preconditions():
                self.say("NAO CONSEGUI começar: pré-condição não satisfeita (login, atalho ou bead)")
                return 3
            if not self.prepare():
                self.say("NAO CONSEGUI começar: o servidor não preparou o worktree/pasta")
                return 3
            if self.start():
                tela = self.watch()
                if MARK in tela:
                    self.check("sessão terminou os 7 passos", True)
                    time.sleep(min(5, POLL))
                    self.evidence()  # (uma exceção aqui — timeout do ssh/bd/git — cai no except do go() como prova que reprova)
                self.say("--- tela final ---\n" + tela[-2500:])
        except (OSError, subprocess.SubprocessError) as e:  # ssh/provider/bd que não responde no prazo: "não consegui" é falha visível, nunca prova que passou
            self.check("execução até o fim sem interrupção", False, f"{type(e).__name__}: {e}")
        finally:
            self.finish()
        bad = [n for n, ok in self.checks if not ok]
        self.say(f"E2E {'PASSOU' if not bad else 'FALHOU'}: {sum(ok for _, ok in self.checks)} de {len(self.checks)} provas" + (f"; faltou: {bad}" if bad else ""))
        return 1 if bad or not self.checks else 0


def cmd_e2e(a: argparse.Namespace) -> int:
    return E2E(a).go()


def _arg(rx: str, what: str):
    """Valor que entra num comando do SERVIDOR (ssh/tmux): só a forma esperada passa; o resto é erro de uso (2), antes de tocar em qualquer lado."""
    def check(v: str) -> str:
        if not re.fullmatch(rx, v):
            raise argparse.ArgumentTypeError(f"{what} inválido: {v!r}")
        return v
    return check


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="hetzner-proof", description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hooks")
    h.add_argument("--json", action="store_true")
    h.add_argument("--only", default="", help="ids de caso separados por vírgula (s04,f01…)")
    la = sub.add_parser("latency")
    la.add_argument("--prompts", type=int, default=20)
    la.add_argument("--timeout", type=int, default=120)
    la.add_argument("--control", type=int, default=10, help="prompts do controle direto no mini (0 desliga)")
    e = sub.add_parser("e2e")
    e.add_argument("--bead", default="ga-2hd02v.1.5.3", type=_arg(r"[a-z]{2,8}-[a-z0-9]{2,16}(\.[0-9]{1,4}){0,3}", "id de bead"))
    e.add_argument("--model", default="haiku", type=_arg(r"[A-Za-z0-9._-]{1,40}", "modelo"))
    e.add_argument("--timeout", type=int, default=900)
    e.add_argument("--log", default="")
    e.add_argument("--keep", action="store_true", help="não remove o worktree do servidor no fim")
    a = ap.parse_args(argv)
    if a.cmd == "latency" and not 1 <= a.prompts <= 200:
        ap.error("--prompts tem que ir de 1 a 200")
    return {"hooks": cmd_hooks, "latency": cmd_latency, "e2e": cmd_e2e}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
