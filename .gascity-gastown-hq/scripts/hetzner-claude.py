#!/usr/bin/env -S python3 -I
"""hetzner-claude — o Claude Code no servidor Hetzner: instala, leva o bundle, diz se o login vale e segura a abertura de sessão
quando não vale. ga-2hd02v.1.4 (fatia 5), desenho do ga-ukxa3k. Python 3.9+, só biblioteca padrão.

Contents
  Subcomandos · Estado e guarda · O que NÃO faz · Configuração · Códigos de saída

SUBCOMANDOS
  gate                      0 só se o login do servidor está POSITIVAMENTE bom; qualquer outra coisa (deslogado, expirado, sem cota,
                            ssh fora, resposta ilegível, estado velho que não deu para renovar, bandeira .off) sai 1 e diz por quê.
                            É o que o provider chama antes de abrir sessão nova (ver docs/runbooks/hetzner-claude-login.md).
  status [--fresh] [--probe]  imprime o estado (JSON) e sai 0 se ok. --fresh ignora o cache; --probe força a chamada de modelo.
  install-claude --installer-sha256 H [--version V]   instala o build nativo (V padrão = o do mini) como o usuário do servidor.
  plugins                   instala no servidor os plugins da lista PLUGINS (iguais aos do mini, sem o github).
  push-bundle --role R --role-dir D --out DIR   monta o bundle da fatia 1, leva ao servidor, confere o hash lá e instala a camada home.
  canary                    sessão mínima do jeito do provider (--settings do bundle, --dangerously-skip-permissions): responde?
  fingerprint [--save F | --compare F]   impressão da credencial do MINI, só atributos: o hash do oauthAccount DECIDE; o mdat do
                            Keychain só informa (o mini renova o token sozinho, então ele anda sem que ninguém mexa).
  leak-scan PATH...         procura formato de token do claude em arquivos; imprime arquivo e contagem, nunca o texto achado.

ESTADO E GUARDA
  <estado>/hetzner-claude.state.json: {state, reason, checked_at, probe, login}; probe = a última chamada de modelo {state, reason, at}. state ∈ ok | logged-out | expired | quota |
  unreachable | unknown. TRÊS respostas, não duas: "não consegui saber" (ssh fora, JSON ilegível, tipo errado) é `unreachable` ou
  `unknown`, e o gate trata como bloqueado. `ok` exige `claude auth status` com loggedIn == true E uma chamada de modelo real
  (haiku, 1 turno) com is_error == false e saída 0: a medição de 14/10 mostrou que um servidor DESLOGADO responde subtype "success"
  com is_error true, então subtype não decide nada. A chamada de modelo é repetida a cada PROBE_OK_TTL (1 h) enquanto ok, e a
  cada PROBE_RETRY (15 min) enquanto expired/quota. Aviso visível: linha no log a cada mudança; `notify` só quando ok -> logged-out
  ou ok -> expired (nunca por cota: a regra da cidade é não mandar aviso de crédito/cota ao celular do Athos).
  Bandeira manual: <estado>/hetzner-claude.off (existir = bloqueado), para o Mayor segurar o servidor na hora.

O QUE NÃO FAZ
  Não faz o login (OAuth interativo, passo do Athos), não lê nem copia credencial, não troca conta, não toca em wa-base, venv-wa,
  slots, traco-bim, mirror nem ~/shared do servidor, e não roda `go build`, `rm -rf` nem nada com sudo.

CONFIGURAÇÃO (ambiente)  HETZNER_SSH_HOST (hetzner-teste) · HETZNER_REMOTE_HOME (/home/runner) · HETZNER_REMOTE_ROOT (<home>/gt-remote/bundle)
  HETZNER_STATE_DIR (<cidade>/.gc) · HETZNER_STATE_TTL (120) · HETZNER_PROBE_OK_TTL (3600) · HETZNER_PROBE_RETRY (900)
  HETZNER_SSH_TIMEOUT (30) · HETZNER_PROBE_TIMEOUT (120) · HETZNER_LOCK_WAIT (20) · HETZNER_INSTALLER_URL (https://claude.ai/install.sh)
  HETZNER_BUILDER (remote-bundle-build.py ao lado deste script; só o selftest troca)

CÓDIGOS  0 ok · 1 bloqueado / falhou · 2 uso ou configuração inválida · 3 recusa de segurança, ou "não consegui ler" (nunca vira "limpo")
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
BUILDER = os.environ.get("HETZNER_BUILDER") or os.path.join(HERE, "remote-bundle-build.py")
CITY = os.environ.get("GC_CITY_PATH") or os.path.dirname(HERE)

HOST_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.@:-]*")
PATH_RE = re.compile(r"/[A-Za-z0-9_./+-]+")  # caminho remoto: absoluto, sem espaço nem aspas (entra em comando de shell)
VER_RE = re.compile(r"\d+\.\d+\.\d+")
SHA_RE = re.compile(r"[0-9a-f]{64}")


def die(code: int, msg: str):
    print(f"hetzner-claude: {msg}", file=sys.stderr)
    sys.exit(code)


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    if not raw.isdigit() or int(raw) < 1:
        die(2, f"{name}={raw!r} não é um inteiro positivo")
    return int(raw)


HOST = os.environ.get("HETZNER_SSH_HOST", "hetzner-teste")
RHOME = os.environ.get("HETZNER_REMOTE_HOME", "/home/runner")
RROOT = os.environ.get("HETZNER_REMOTE_ROOT", RHOME + "/gt-remote/bundle")
STATE_DIR = os.environ.get("HETZNER_STATE_DIR") or os.path.join(CITY, ".gc")
STATE_FILE = os.path.join(STATE_DIR, "hetzner-claude.state.json")
LOCK_FILE = os.path.join(STATE_DIR, "hetzner-claude.lock")
OFF_FILE = os.path.join(STATE_DIR, "hetzner-claude.off")
LOG_FILE = os.path.join(STATE_DIR, "hetzner-claude.log")
INSTALLER_URL = os.environ.get("HETZNER_INSTALLER_URL", "https://claude.ai/install.sh")
TTL = _env_int("HETZNER_STATE_TTL", 120)
PROBE_OK_TTL = _env_int("HETZNER_PROBE_OK_TTL", 3600)
PROBE_RETRY = _env_int("HETZNER_PROBE_RETRY", 900)
SSH_TIMEOUT = _env_int("HETZNER_SSH_TIMEOUT", 30)
PROBE_TIMEOUT = _env_int("HETZNER_PROBE_TIMEOUT", 120)
LOCK_WAIT = _env_int("HETZNER_LOCK_WAIT", 20)

if not HOST_RE.fullmatch(HOST):
    die(2, f"HETZNER_SSH_HOST inválido: {HOST!r}")
for _n, _v in (("HETZNER_REMOTE_HOME", RHOME), ("HETZNER_REMOTE_ROOT", RROOT)):
    if not PATH_RE.fullmatch(_v) or _v.endswith("/") or ".." in _v.split("/"):
        die(2, f"{_n} inválido (absoluto, sem espaço, aspas, '..' nem barra no fim): {_v!r}")
if RHOME.count("/") < 2:
    die(2, f"HETZNER_REMOTE_HOME precisa ter ao menos dois níveis (ex.: /home/runner): {RHOME!r}")

STATES = ("ok", "logged-out", "expired", "quota", "unreachable", "unknown")
MARKET, MARKET_REPO = "claude-plugins-official", "anthropics/claude-plugins-official"
# security-guidance entra, mas NÃO é idêntico ao do mini (mesma versão 2.0.13, 5 arquivos diferentes: medido 14/10); o runbook diz.
# playwright fica fora: `npx @playwright/mcp@latest` sem versão fixa a cada sessão, precisa de node e de navegador. beads não está
# instalado nem no mini. github é proibido (credencial).
PLUGINS = ("superpowers", "security-guidance", "frontend-design")
PLUGIN_KEYS = ("enabledPlugins", "extraKnownMarketplaces")
REMOTE_PATH = 'export PATH="$HOME/.local/bin:$PATH"; '
PROBE_CMD = (REMOTE_PATH + 'd=$(mktemp -d) || exit 125; cd "$d" || exit 125; '
             'timeout 90 claude -p "Responda apenas: OK" --model haiku --output-format json --no-session-persistence '
             '--setting-sources local </dev/null; rc=$?; cd /; rmdir "$d" 2>/dev/null; exit $rc')
EXPIRED_RE = re.compile(r"not logged in|/login|log in|expired|invalid.{0,20}(token|credential)|unauthori[sz]ed|authentication|\b401\b", re.I)
QUOTA_RE = re.compile(r"usage limit|limit reached|rate.?limit|quota|too many requests|\b429\b|credit balance|out of (extra )?usage", re.I)
TOKEN_RES = (re.compile(rb"sk-ant-[A-Za-z0-9_-]{16,}"), re.compile(rb'"(?:access|refresh)Token"\s*:\s*"[A-Za-z0-9._-]{16,}"'),
             re.compile(rb"claudeAiOauth"))


def log(msg: str) -> None:
    line = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + msg
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        print(f"hetzner-claude: não consegui gravar o log ({e}): {line}", file=sys.stderr)


class Res:
    def __init__(self, rc, out="", err="", timed_out=False):
        self.rc, self.out, self.err, self.timed_out = rc, out, err, timed_out

    @property
    def conn_failed(self) -> bool:  # ssh não chegou a rodar o comando: 255 é o código do próprio ssh; None = timeout / sem binário
        return self.rc is None or self.rc == 255


def ssh(cmd: str, timeout: int = SSH_TIMEOUT, stdin: bytes | None = None) -> Res:
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, cmd]
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return Res(None, timed_out=True)
    except OSError as e:
        return Res(None, err=str(e))
    return Res(p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace"))


def _short(s: str, n: int = 160) -> str:
    return " ".join(s.split())[:n]


# ---------------------------------------------------------------- login: leitura e classificação

def check_login():
    """(estado, motivo, login). estado ∈ logged-in | logged-out | unreachable | unknown — nunca 'ok': isso só sai da chamada de modelo."""
    r = ssh(REMOTE_PATH + "claude auth status --json")
    if r.conn_failed:
        return "unreachable", "ssh não chegou ao servidor" + (" (timeout)" if r.timed_out else f" (rc={r.rc} {_short(r.err, 80)})"), None
    try:
        j = json.loads(r.out)
    except ValueError:
        return "unknown", f"claude auth status sem JSON (rc={r.rc}): {_short(r.out or r.err, 100)}", None
    if not isinstance(j, dict) or not isinstance(j.get("loggedIn"), bool):
        return "unknown", "claude auth status sem loggedIn booleano", None
    login = {k: j.get(k) for k in ("loggedIn", "authMethod", "apiProvider") if isinstance(j.get(k), (bool, str))}
    if j["loggedIn"] is False:
        return "logged-out", "servidor sem login (claude auth status: loggedIn=false)", login
    if r.rc != 0:
        return "unknown", f"loggedIn=true mas claude auth status saiu {r.rc}", login
    return "logged-in", "", login


def classify_probe(rc, out: str):
    """(estado, motivo) de uma chamada `claude -p --output-format json`. ok só com rc 0, type result e is_error EXATAMENTE False."""
    try:
        j = json.loads(out)
    except ValueError:
        return "unknown", f"chamada de modelo sem JSON (rc={rc}): {_short(out, 100)}"
    if not isinstance(j, dict) or j.get("type") != "result" or not isinstance(j.get("is_error"), bool):
        return "unknown", "chamada de modelo sem type=result / is_error booleano"
    if j["is_error"] is False:
        return ("ok", "") if rc == 0 else ("unknown", f"is_error=false mas o claude saiu {rc}")
    txt = _short(str(j.get("result", "")), 200)
    if QUOTA_RE.search(txt):
        return "quota", f"sem cota: {txt}"
    if EXPIRED_RE.search(txt):
        return "expired", f"login não vale: {txt}"
    return "unknown", f"erro de modelo não reconhecido: {txt}"


def probe(cmd: str = PROBE_CMD):
    r = ssh(cmd, PROBE_TIMEOUT)
    if r.conn_failed:
        return "unreachable", "ssh não chegou ao servidor na chamada de modelo"
    return classify_probe(r.rc, r.out)


# ---------------------------------------------------------------- estado

def read_state():
    try:
        with open(STATE_FILE) as f:
            st = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        log(f"estado ilegível ({e}); vou medir de novo")
        return None
    ok = (isinstance(st, dict) and st.get("state") in STATES and isinstance(st.get("reason"), str)
          and isinstance(st.get("checked_at"), (int, float)) and not isinstance(st.get("checked_at"), bool))
    if not ok:
        log("estado com forma inesperada; vou medir de novo")
        return None
    return st


def write_state(st: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = f"{STATE_FILE}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, STATE_FILE)


def fresh(st, now: float) -> bool:  # data no futuro (relógio, edição à mão) não é "recente": é ilegível
    return st is not None and 0 <= now - st["checked_at"] < TTL


def valid_probe(pr) -> bool:
    return (isinstance(pr, dict) and pr.get("state") in STATES and isinstance(pr.get("reason"), str)
            and isinstance(pr.get("at"), (int, float)) and not isinstance(pr.get("at"), bool))


def refresh(prev, force_probe: bool = False) -> dict:
    now = time.time()
    verdict, why, login = check_login()
    pr = prev.get("probe") if prev else None
    pr = pr if valid_probe(pr) else None
    if verdict != "logged-in":
        state, reason = verdict, why
        if verdict == "logged-out":  # a credencial sumiu: o veredito da chamada anterior era de OUTRA credencial, o próximo login mede de novo
            pr = None
    else:
        window = PROBE_OK_TTL if pr and pr["state"] == "ok" else PROBE_RETRY
        if force_probe or pr is None or not 0 <= now - pr["at"] < window:
            ps, pw = probe()
            if ps != "unreachable":  # sem resposta não é veredito: o registro da última chamada que respondeu fica como está
                pr = {"state": ps, "reason": pw, "at": now}
            state, reason = (ps, pw) if ps == "unreachable" else (pr["state"], pr["reason"])
        else:
            state, reason = pr["state"], pr["reason"]
    st = {"state": state, "reason": reason, "checked_at": now, "probe": pr, "login": login}
    transition(prev["state"] if prev else None, state, reason)
    return st


def transition(old, new, reason: str) -> None:
    if old == new:
        return
    log(f"estado {old or '-'} -> {new}: {reason}")
    if old == "ok" and new in ("logged-out", "expired"):
        try:
            subprocess.run(["notify", "-t", "Hetzner claude", f"login do servidor: {new} — sessões novas lá estão seguradas"],
                           capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as e:
            log(f"notify falhou: {e}")


class Lock:
    def __enter__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        self.f, self.got = open(LOCK_FILE, "a"), False
        deadline = time.time() + LOCK_WAIT
        while not self.got:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.got = True
            except OSError:
                if time.time() >= deadline:
                    break
                time.sleep(0.2)
        return self

    def __exit__(self, *_):
        self.f.close()


def current(fresh_only: bool = False, force_probe: bool = False):
    """(estado, avisos). Cache dentro do TTL; vencido -> mede sob lock; sem lock e vencido -> NÃO devolve o velho como se valesse."""
    if os.path.exists(OFF_FILE):
        return {"state": "unknown", "reason": f"bandeira manual {OFF_FILE} existe (servidor seguro à mão)", "checked_at": time.time()}
    st = read_state()
    if not fresh_only and not force_probe and fresh(st, time.time()):
        return st
    with Lock() as lk:
        if not lk.got:
            return {"state": "unknown", "reason": f"estado vencido e outro processo o atualiza há mais de {LOCK_WAIT}s", "checked_at": time.time()}
        st = refresh(read_state(), force_probe)
        write_state(st)
        return st


def cmd_gate(a) -> int:
    try:
        st = current()
    except Exception as e:  # noqa: BLE001 — falha inesperada NUNCA vira "ok": bloqueia e diz por quê
        print(f"blocked: unknown: erro interno: {type(e).__name__}: {_short(str(e), 120)}")
        return 1
    if st["state"] == "ok":
        print("ok")
        return 0
    print(f"blocked: {st['state']}: {st['reason']}")
    return 1


def cmd_status(a) -> int:
    st = current(a.fresh or a.probe, a.probe)
    print(json.dumps(st, sort_keys=True, ensure_ascii=False, indent=1))
    return 0 if st["state"] == "ok" else 1


# ---------------------------------------------------------------- instalação

def local_version():
    try:
        p = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"(\d+\.\d+\.\d+)", p.stdout.strip())
    return m.group(1) if m else None


def remote_version():
    r = ssh(REMOTE_PATH + "claude --version")
    m = re.match(r"(\d+\.\d+\.\d+)", r.out.strip()) if not r.conn_failed and r.rc == 0 else None
    return m.group(1) if m else None


def cmd_install_claude(a) -> int:
    if not SHA_RE.fullmatch(a.installer_sha256):
        die(2, "--installer-sha256 precisa de 64 hex minúsculos")
    want = a.version or local_version()
    if not want or not VER_RE.fullmatch(want):
        die(2, f"versão inválida ou não consegui ler a do mini: {want!r}")
    have = remote_version()
    if have == want:
        print(f"claude {want} já instalado no servidor")
        return 0
    try:
        with urllib.request.urlopen(INSTALLER_URL, timeout=30) as resp:
            body = resp.read()
    except (OSError, ValueError) as e:
        die(1, f"não consegui baixar o instalador: {e}")
    got = hashlib.sha256(body).hexdigest()
    if got != a.installer_sha256:
        die(3, f"o instalador mudou (sha256 {got}); não rodo um script que ninguém leu — leia o novo e passe o hash")
    script = (f'f=$(mktemp) || exit 125; cat >"$f"; echo "{got}  $f" | sha256sum -c - >/dev/null || {{ rm -f "$f"; exit 126; }}; '
              f'bash "$f" {want}; rc=$?; rm -f "$f"; exit $rc')
    r = ssh(script, 300, body)
    print(_short(r.out[-400:], 400))
    if r.rc != 0:
        die(1, f"instalador saiu {r.rc}: {_short(r.err, 200)}")
    now = remote_version()
    if now != want:
        die(1, f"depois da instalação o servidor diz {now!r}, esperado {want}")
    print(f"claude {want} instalado no servidor")
    return 0


def remote_json(cmd: str):
    r = ssh(REMOTE_PATH + cmd)
    if r.conn_failed or r.rc != 0:
        return None
    try:
        return json.loads(r.out)
    except ValueError:
        return None


def cmd_plugins(a) -> int:
    markets = remote_json("claude plugin marketplace list --json")
    if not isinstance(markets, list):
        die(1, "não consegui listar os marketplaces do servidor")
    if not any(isinstance(m, dict) and m.get("name") == MARKET for m in markets):
        r = ssh(REMOTE_PATH + f"GIT_TERMINAL_PROMPT=0 timeout 120 claude plugin marketplace add {MARKET_REPO}", 150)
        if r.rc != 0:
            die(1, f"marketplace add saiu {r.rc}: {_short(r.out + r.err, 200)}")
    listed = remote_json("claude plugin list --json")
    if not isinstance(listed, list):
        die(1, "não consegui listar os plugins do servidor")
    have = {p.get("id") for p in listed if isinstance(p, dict)}
    for p in PLUGINS:
        if f"{p}@{MARKET}" not in have:
            r = ssh(REMOTE_PATH + f"GIT_TERMINAL_PROMPT=0 timeout 120 claude plugin install {p}@{MARKET}", 150)
            if r.rc != 0:
                die(1, f"install {p} saiu {r.rc}: {_short(r.out + r.err, 200)}")
    final = {p["id"]: p for p in (remote_json("claude plugin list --json") or []) if isinstance(p, dict) and "id" in p}
    bad = [p for p in PLUGINS if not (f"{p}@{MARKET}" in final and final[f"{p}@{MARKET}"].get("enabled") is True)]
    for p in PLUGINS:
        e = final.get(f"{p}@{MARKET}", {})
        print(f"{p}@{MARKET}\t{e.get('version', '?')}\tenabled={e.get('enabled', '?')}")
    if bad:
        die(1, f"faltam ou estão desligados no servidor: {', '.join(bad)}")
    return 0


# ---------------------------------------------------------------- bundle

BUNDLE_OUT = "gt-remote/bundle-out"  # cópia verificada do OUT no servidor; só este comando escreve aqui (o único rsync --delete é ali)
# Roda NO servidor (python3 -I - OUT RROOT RHOME MERGED ALLOWED < este texto): instala cada arquivo do manifesto onde manifest.install
# manda e confere o sha256 e o bit de execução depois. NÃO apaga o que o bundle não pôs (RROOT/work é de outras fatias); o único
# apagar é o de arquivo que o bundle ANTERIOR instalou e o novo não tem. role/* fica em OUT: quem monta o diretório da sessão o coloca.
INSTALL_PY = r"""
import hashlib, json, os, sys
out, rroot, rhome, merged, allowed = sys.argv[1:6]
allowed = set(json.loads(allowed))
roots = (os.path.normpath(rroot) + "/city/", os.path.normpath(rhome) + "/.claude/")
def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()
def dest(rel):
    if ".." in rel.split("/"):
        sys.exit("caminho com .. no manifesto: " + rel)
    if rel == "city/settings.json":
        return rroot + "/city/settings.json"
    if rel.startswith("home/.claude/"):
        return rhome + "/.claude/" + rel[len("home/.claude/"):]
    if rel.startswith("role/"):
        return None
    sys.exit("camada desconhecida no manifesto: " + rel)
def inside(d):
    return any(os.path.normpath(d).startswith(r) for r in roots)
def linked(d):
    x = os.path.normpath(d)
    base = next(r for r in roots if x.startswith(r))
    while len(x) >= len(base) - 1:
        if os.path.islink(x):
            return True
        x = os.path.dirname(x)
    return False
m = json.load(open(out + "/manifest.json"))
plan = {}
for rel, info in m["files"].items():
    d = dest(rel)
    if d is None:
        continue
    if not inside(d):
        sys.exit("destino fora das raizes do bundle: " + d)
    if linked(d):
        sys.exit("symlink no destino: " + d)
    plan[d] = (merged if rel == "home/.claude/settings.json" else out + "/" + rel, info["exec"])
sp = rhome + "/.claude/settings.json"
if os.path.lexists(sp):
    try:
        with open(sp) as f:
            cur = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("settings.json do servidor ilegivel: %s" % e)
    if not isinstance(cur, dict):
        sys.exit("settings.json do servidor nao e um objeto")
    extra = sorted(set(cur) - allowed)
    if extra:
        sys.exit("settings.json do servidor tem chaves que o bundle nao conhece (%s); nao sobrescrevo" % ",".join(extra))
recp = rhome + "/gt-remote/bundle-installed.json"
try:
    with open(recp) as f:
        prev = json.load(f)
    if not isinstance(prev, list) or not all(isinstance(x, str) for x in prev):
        raise ValueError("forma")
except FileNotFoundError:
    prev = []
except (OSError, ValueError):
    prev = None
for d, (src, ex) in sorted(plan.items()):
    os.makedirs(os.path.dirname(d), exist_ok=True)
    with open(src, "rb") as f:
        data = f.read()
    tmp = d + ".bundle-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o755 if ex else 0o644)
    os.replace(tmp, d)
bad = [d for d, (src, ex) in plan.items() if sha(d) != sha(src) or bool(os.stat(d).st_mode & 0o100) != bool(ex)]
if bad:
    sys.exit("depois de copiar, nao batem: " + ", ".join(sorted(bad)))
gone = 0
if prev is None:
    print("registro anterior ilegivel: nada removido")
else:
    for d in sorted(set(prev) - set(plan)):
        if inside(d) and os.path.isfile(d) and not os.path.islink(d):
            os.remove(d)
            gone += 1
tmp = recp + ".tmp"
with open(tmp, "w") as f:
    json.dump(sorted(plan), f)
os.replace(tmp, recp)
print("ok %d arquivos, %d removidos (do bundle anterior)" % (len(plan), gone))
"""


def merged_home_settings(path: str) -> dict:
    with open(path) as f:
        base = json.load(f)
    if not isinstance(base, dict):
        die(3, f"{path} não é um objeto JSON")
    clash = [k for k in PLUGIN_KEYS if k in base]
    if clash:
        die(3, f"o bundle já traz {', '.join(clash)}; não sobrescrevo (decida de quem é a chave)")
    base["enabledPlugins"] = {f"{p}@{MARKET}": True for p in PLUGINS}
    base["extraKnownMarketplaces"] = {MARKET: {"source": {"source": "github", "repo": MARKET_REPO}}}
    return base


def run(argv, what: str) -> None:
    p = subprocess.run(argv)
    if p.returncode != 0:
        die(1, f"{what} saiu {p.returncode}")


def cmd_push_bundle(a) -> int:
    out = os.path.realpath(a.out)
    build = [sys.executable, "-I", BUILDER, "build", "--city", CITY, "--claude-home", os.path.expanduser("~/.claude"), "--role", a.role,
             "--role-dir", a.role_dir, "--remote-root", RROOT, "--remote-home", RHOME, "--out", out]
    run(build + (["--skills"] if a.skills else []), "remote-bundle-build build")
    run([sys.executable, "-I", BUILDER, "verify", out], "remote-bundle-build verify (mini)")
    with open(os.path.join(out, "manifest.json")) as f:
        want = json.load(f).get("bundle_hash")
    if not isinstance(want, str) or not SHA_RE.fullmatch(want):
        die(3, "manifest.json sem bundle_hash legível")
    home_settings = os.path.join(out, "home", ".claude", "settings.json")
    merged = merged_home_settings(home_settings)
    with open(home_settings) as f:
        allowed = sorted(set(json.load(f)) | set(PLUGIN_KEYS))
    stage, q = f"{RHOME}/{BUNDLE_OUT}", shlex.quote
    r = ssh(f"mkdir -p {q(stage)} {q(RHOME + '/gt-remote/bin')}")
    if r.rc != 0:
        die(1, f"mkdir no servidor saiu {r.rc}: {_short(r.err, 160)}")
    run(["rsync", "-a", "--delete", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", out + "/", f"{HOST}:{stage}/"], "rsync do bundle")
    with open(BUILDER, "rb") as f:
        r = ssh(f"cat > {q(RHOME)}/gt-remote/bin/remote-bundle-build.py && chmod 755 {q(RHOME)}/gt-remote/bin/remote-bundle-build.py", stdin=f.read())
    if r.rc != 0:
        die(1, f"não consegui levar o builder: {_short(r.err, 160)}")
    r = ssh(f"python3 -I {q(RHOME)}/gt-remote/bin/remote-bundle-build.py verify {q(stage)}")
    if r.rc != 0:
        die(1, f"verify NO SERVIDOR saiu {r.rc}: {_short(r.out + r.err, 200)}")
    r = ssh(f"python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"bundle_hash\"])' {q(stage)}/manifest.json")
    if r.rc != 0 or r.out.strip() != want:
        die(1, f"bundle_hash do servidor {r.out.strip()[:16]!r} != o do mini {want[:16]}")
    mpath = f"{RHOME}/gt-remote/home-settings.merged.json"
    r = ssh(f"cat > {q(mpath)}", stdin=(json.dumps(merged, indent=2, sort_keys=True) + "\n").encode())
    if r.rc != 0:
        die(1, f"não consegui gravar o settings mesclado: {_short(r.err, 160)}")
    r = ssh(f"python3 -I - {q(stage)} {q(RROOT)} {q(RHOME)} {q(mpath)} {q(json.dumps(allowed))}", stdin=INSTALL_PY.encode())
    if r.rc != 0:
        die(1, f"instalação no servidor saiu {r.rc}: {_short(r.out + r.err, 240)}")
    log(f"bundle {want[:12]} instalado e conferido no servidor: {_short(r.out, 120)}")
    print(f"bundle_hash {want[:12]} no servidor (verify lá = 0); {_short(r.out, 120)}; plugins {', '.join(PLUGINS)} no settings")
    return 0


def cmd_canary(a) -> int:
    cmd = (REMOTE_PATH + f'd={shlex.quote(RHOME)}/gt-remote/canary; mkdir -p "$d" && cd "$d" || exit 125; '
           f'timeout 100 claude -p "Responda apenas: OK" --settings {shlex.quote(RROOT)}/city/settings.json --dangerously-skip-permissions '
           f'--model sonnet --output-format json --no-session-persistence </dev/null')
    state, why = probe(cmd)
    print(f"canary: {state}" + (f": {why}" if why else ""))
    return 0 if state == "ok" else 1


# ---------------------------------------------------------------- provas sobre a credencial do mini

INFO_ONLY = "keychain_mdat"


def fingerprint() -> dict:
    fp = {}
    try:
        with open(os.path.expanduser("~/.claude.json")) as f:
            o = json.load(f).get("oauthAccount")
        fp["oauthAccount_sha256_16"] = "absent" if o is None else hashlib.sha256(json.dumps(o, sort_keys=True).encode()).hexdigest()[:16]
    except (OSError, ValueError, AttributeError):
        fp["oauthAccount_sha256_16"] = "unknown"
    fp["keychain_mdat"] = "n/a"
    if sys.platform == "darwin":
        fp["keychain_mdat"] = "unknown"
        try:  # sem -g e sem -w: o macOS devolve só atributos, nunca o segredo
            p = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials"], capture_output=True, text=True, timeout=15)
            m = re.search(r'"mdat"<timedate>=\S+\s+"(\d{14}Z)', p.stdout)
            if p.returncode == 0 and m:
                fp["keychain_mdat"] = m.group(1)
        except (OSError, subprocess.SubprocessError):
            pass
    return fp


def cmd_fingerprint(a) -> int:
    now = fingerprint()
    if a.save:
        with open(a.save, "w") as f:
            json.dump(now, f, sort_keys=True)
        print(json.dumps(now, sort_keys=True))
        return 0
    if not a.compare:
        print(json.dumps(now, sort_keys=True))
        return 0
    try:
        with open(a.compare) as f:
            before = json.load(f)
    except (OSError, ValueError) as e:
        die(3, f"não consegui ler {a.compare}: {e}")
    rc = 0
    for k in sorted(set(now) | set(before)):
        b, n = before.get(k, "unknown"), now.get(k, "unknown")
        if k == INFO_ONLY:  # o mini renova o próprio token o dia todo: o mdat anda sozinho (medido 14/10: 16:29Z -> 22:32Z em 12 min)
            print(f"{k}: antes={b} depois={n} -> só informa, não decide")
            continue
        verdict = "igual" if b == n and "unknown" not in (b, n) else ("NÃO SEI" if "unknown" in (b, n) else "MUDOU")
        print(f"{k}: antes={b} depois={n} -> {verdict}")
        rc = max(rc, {"igual": 0, "MUDOU": 1, "NÃO SEI": 3}[verdict])
    return rc


def cmd_leak_scan(a) -> int:
    hits, unreadable, files, links = [], [], 0, 0
    for root in a.paths:
        walk = [(os.path.dirname(root), [], [os.path.basename(root)])] if os.path.isfile(root) else os.walk(root, onerror=lambda e: unreadable.append(str(e.filename)))
        for dp, _dn, fn in walk:
            for name in fn:
                p = os.path.join(dp, name)
                try:
                    if os.path.islink(p):
                        links += 1
                        continue
                    if os.path.getsize(p) > 20_000_000:
                        unreadable.append(p + " (maior que 20 MB)")
                        continue
                    with open(p, "rb") as f:
                        data = f.read()
                except OSError:
                    unreadable.append(p)
                    continue
                files += 1
                n = sum(len(rx.findall(data)) for rx in TOKEN_RES)
                if n:
                    hits.append((p, n))
    for p, n in hits:
        print(f"ACHOU formato de token: {p} ({n})")
    for p in unreadable:
        print(f"NÃO CONSEGUI LER: {p}")
    print(f"{files} arquivos lidos, {len(hits)} com formato de token, {len(unreadable)} ilegíveis, {links} symlinks não seguidos")
    return 1 if hits else (3 if unreadable or files == 0 else 0)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="hetzner-claude", description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("gate").set_defaults(fn=cmd_gate)
    s = sp.add_parser("status")
    s.add_argument("--fresh", action="store_true")
    s.add_argument("--probe", action="store_true")
    s.set_defaults(fn=cmd_status)
    s = sp.add_parser("install-claude")
    s.add_argument("--installer-sha256", required=True)
    s.add_argument("--version")
    s.set_defaults(fn=cmd_install_claude)
    sp.add_parser("plugins").set_defaults(fn=cmd_plugins)
    s = sp.add_parser("push-bundle")
    s.add_argument("--role", required=True)
    s.add_argument("--role-dir", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--skills", action="store_true")
    s.set_defaults(fn=cmd_push_bundle)
    sp.add_parser("canary").set_defaults(fn=cmd_canary)
    s = sp.add_parser("fingerprint")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--save")
    g.add_argument("--compare")
    s.set_defaults(fn=cmd_fingerprint)
    s = sp.add_parser("leak-scan")
    s.add_argument("paths", nargs="+")
    s.set_defaults(fn=cmd_leak_scan)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
