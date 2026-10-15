#!/usr/bin/env python3
"""remote-shim-wrapper.py — lado do MINI do atalho bd/gc/gate-done do servidor Hetzner (ga-2hd02v.1.2, desenho do ga-ukxa3k).

Contents
  O que é · Protocolo · Lista permitida · Por que recusa em vez de adaptar · Subcomandos · Códigos de saída

O QUE É
  É o ÚNICO programa que a chave ssh do servidor consegue rodar no mini: a linha do authorized_keys é
  `restrict,[from=…,]command="<python> -I <este arquivo> serve --config <conf>" <chave>` (o subcomando `authorized-line` a imprime).
  Não existe shell: o pedido chega em SSH_ORIGINAL_COMMAND, é decodificado, comparado com a LISTA abaixo e executado como argv
  (subprocess sem shell), com ambiente montado do zero. Fora da lista não roda nada: sai 77 e o bd/gc de verdade nem é chamado.

PROTOCOLO (v1)
  SSH_ORIGINAL_COMMAND = `rs1 <base64url sem padding de um JSON {"tool": "bd"|"gc"|"gate-done", "argv": [texto...], "env": {NOME: texto}}>`.
  O JSON vai codificado porque o ssh entrega a linha ao shell de login do mini; base64url não tem caractere que o shell interprete, e o
  argv chega inteiro, byte a byte. Chave duplicada, chave a mais, tipo errado, NUL, surrogate solto, tamanho acima do teto → recusa.
  `env` só aceita as variáveis de IDENTIDADE da sessão (ENV_VAL): GC_BIN, GC_HOME, GC_CITY_PATH, GC_DOLT_PORT... NÃO são aceitas (apontariam
  o gc/bd do mini para outro lugar), nem GC_SESSION_ID (nenhum padrão o liga ao alias; o `gc handoff` aceita o alias). Toda requisição precisa de
  GC_ALIAS (ou GC_AGENT), e tudo que diz QUEM é a sessão (alias, agent, nome da sessão, template) tem que casar com `identity_pattern` da config
  (o Mayor/coordenadores não casam): é a identidade que vira BEADS_ACTOR e a que o gc usa. É declaração do servidor, não prova — o que limita
  o estrago é o padrão da config, não a honestidade do cliente.

LISTA PERMITIDA
  É a tabela RULES (`list` a imprime; o runbook carrega a mesma saída e o selftest confere as duas). Cada regra é uma forma EXATA: palavras
  fixas, flags nomeadas, valores validados; o argv executado é o do cliente, na ordem dele, só com a flag curta trocada pela longa. Flag fora
  da regra, repetida, valor fora do formato, argumento a mais ou a menos → recusa. Sem `--flag=valor`. `bd -C <dir>` só vale para a cidade ou
  um rig da routes.jsonl (caminho real ou nome); sem routes.jsonl legível o `-C` é recusado. `bd update` só grava chaves ALLOW_META; o alvo
  de `gc session nudge` tem que casar com `nudge_pattern` (sem a chave na config, nudge não roda).

POR QUE RECUSA EM VEZ DE ADAPTAR (está na lista / não está / não consegui saber — o último não vira "está")
  Config ilegível, routes.jsonl ilegível, log de auditoria que não grava, identidade fora do padrão, ferramenta que não achei → não executa.
  A requisição é registrada (hash do argv, nunca o texto) ANTES de rodar; sem rastro não há execução.

SUBCOMANDOS
  serve --config CONF                    forced-command (SSH_ORIGINAL_COMMAND na entrada)
  list                                   imprime a lista permitida (regras e variáveis de ambiente)
  authorized-line --config CONF --pubkey ARQ.pub [--from CIDR[,CIDR]]   imprime a linha do authorized_keys; NÃO grava nada

CONFIG (JSON): {"city": "/abs", "identity_pattern": "regex", "nudge_pattern": "regex", "gate_done_bin": "/abs"|null, "log": "/abs", "timeout_s": 300, "bin_dirs": ["/abs"]}
  Só `city` e `identity_pattern` são obrigatórios (sem `nudge_pattern` o nudge é recusado); chave desconhecida é erro.

CÓDIGOS: o do comando executado · 77 recusado · 124 estourou timeout_s · 126 não consegui executar · 127 ferramenta não encontrada · 2 uso.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pwd
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

REFUSED, TIMEOUT, NOEXEC, NOTFOUND = 77, 124, 126, 127
PROTO = "rs1"
MAX_CMD, MAX_ARGS, MAX_TEXT = 200_000, 64, 20_000
ALLOW_META = ("athos.", "story.")  # as únicas chaves que fórmula/agente de worker escreve (grep em 14/10); gc./pilot./gate./delivery. são plano de controle, o resto é desconhecido: recusa


class Refused(Exception):
    def __init__(self, msg, rc=77):
        super().__init__(msg)
        self.rc = rc


def _fm(p: str):
    c = re.compile(p)
    return lambda s: c.fullmatch(s) is not None


ID = r"[A-Za-z][A-Za-z0-9]{0,15}-[A-Za-z0-9]{1,16}(?:\.[0-9]{1,4}){0,3}"


def v_text(s: str) -> bool:
    return 0 < len(s) <= MAX_TEXT and "\0" not in s


def no_surrogate(s: str) -> bool:  # surrogate solto vira byte cru (0x80-0xFF) no argv do filho, e v_line não o enxerga
    return re.search(r"[\ud800-\udfff]", s) is None


def v_line(s: str) -> bool:  # texto que vira digitação no terminal de OUTRA sessão: sem ESC, CR, LF nem outro controle C0/C1 (só tab)
    return v_text(s) and not re.search(r"[\x00-\x08\x0a-\x1f\x7f-\x9f]", s)


def v_kv(s: str) -> bool:
    k, sep, val = s.partition("=")
    return bool(sep) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]{0,63}", k) is not None \
        and k.startswith(ALLOW_META) and len(val) <= 4000 and "\0" not in val


def v_n(s: str) -> bool:  # --limit 0 é "tudo": varredura de beads inteiros não sai do mini
    return re.fullmatch(r"[1-9][0-9]{0,2}", s) is not None and int(s) <= 200


VAL = {"id": _fm(ID), "ids": _fm(ID + "(?:," + ID + "){0,49}"), "word": _fm(r"[A-Za-z0-9][A-Za-z0-9._:@/-]{0,79}"),
       "status": _fm(r"[a-z_]{1,20}(?:,[a-z_]{1,20}){0,5}"), "kv": v_kv, "text": v_text, "line": v_line, "n": v_n,
       "delivery": _fm(r"wait-idle|queue")}
_IDENT = r"[A-Za-z0-9][A-Za-z0-9._@/-]{0,95}"
# única entrada de ambiente aceita do cliente (e o valor tem formato): o servidor declara QUEM é a sessão, nada que aponte caminho
ENV_VAL = {"GC_AGENT": _IDENT, "GC_ALIAS": _IDENT, "GC_SESSION_NAME": _IDENT, "GC_TEMPLATE": _IDENT,
           "GC_SESSION_ORIGIN": r"[a-z]{1,20}", "GC_MANAGED_SESSION_HOOK": r"1", "GC_HOOK_EVENT_NAME": r"[A-Za-z]{1,30}"}


class F:  # uma flag: val = nome em VAL (ou None se não leva valor), rep = pode repetir, req = obrigatória, short = apelido curto
    def __init__(self, val=None, rep=False, req=False, short=None):
        self.val, self.rep, self.req, self.short = val, rep, req, short


class Rule:
    def __init__(self, tool, words, pos=(), flags=None):
        self.tool, self.words, self.pos, self.flags = tool, tuple(words), list(pos), dict(flags or {})
        self.short = {f.short: n for n, f in self.flags.items() if f.short}

    def label(self) -> str:  # a linha que o runbook mostra: gerada da regra, então não há duas verdades
        w = " ".join(shlex.quote(x) if " " in x else x for x in self.words)
        s = [self.tool + (" [-C <rig>]" if self.tool == "bd" else ""), w] if w else [self.tool]
        for val, lo, hi in self.pos:
            s.append(f"<{val}>" + ("..." if hi > 1 else ""))
        for n, f in self.flags.items():
            nm = n + (f"|{f.short}" if f.short else "") + (f" <{'key=value' if f.val == 'kv' else f.val}>" if f.val else "")
            s.append((nm if f.req else f"[{nm}]") + ("..." if f.rep else ""))
        return " ".join(s)

    def apply(self, args: list[str]) -> list[str]:
        """Recebe o argv depois das palavras fixas; devolve os argumentos a executar (a ORDEM do cliente, flags curtas viram longas) ou levanta Refused."""
        out, pos, seen, i, dd = [], [], set(), 0, False
        while i < len(args):
            a = args[i]
            if dd or not a.startswith("-") or a == "-":
                pos.append(a)
                out.append(a)
                i += 1
            elif a == "--":  # fim das flags: o que vem depois é posicional, mesmo que comece com `-` (só texto livre aceita isso)
                dd, i = True, i + 1
                out.append(a)
            else:
                name = self.short.get(a, a)
                f = self.flags.get(name)
                if f is None:
                    raise Refused(f"flag fora da lista: {a[:40]!r}")
                if name in seen and not f.rep:
                    raise Refused(f"flag repetida: {name}")
                seen.add(name)
                if f.val is None:
                    out.append(name)
                    i += 1
                else:
                    if i + 1 >= len(args) or not VAL[f.val](args[i + 1]):
                        raise Refused(f"{name} sem valor ou com valor fora do formato <{f.val}>")
                    out += [name, args[i + 1]]
                    i += 2
        for n, f in self.flags.items():
            if f.req and n not in seen:
                raise Refused(f"falta {n}")
        p = 0
        for gi, (val, lo, hi) in enumerate(self.pos):
            take = min(hi, len(pos) - p - sum(g[1] for g in self.pos[gi + 1:]))
            if take < lo:
                raise Refused(f"faltam argumentos <{val}>")
            for tok in pos[p:p + take]:
                if not VAL[val](tok):
                    raise Refused(f"argumento fora do formato <{val}>")
            p += take
        if p != len(pos):
            raise Refused("argumento a mais")
        return out


_J = {"--json": F()}
RULES = [
    Rule("bd", ["show"], [("id", 1, 1)], _J),
    Rule("bd", ["list"], [], {**_J, "--status": F("status", short="-s"), "--assignee": F("word", short="-a"),
                              "--label": F("word", rep=True, short="-l"), "--parent": F("id"), "--limit": F("n", short="-n"),
                              "--id": F("ids")}),
    Rule("bd", ["update"], [("id", 1, 1)], {**_J, "--set-metadata": F("kv", rep=True, req=True)}),
    Rule("bd", ["comment"], [("id", 1, 1), ("text", 1, 50)], {}),
    Rule("bd", ["comment"], [("id", 1, 1)], {"--stdin": F(req=True)}),
    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}),
    Rule("gc", ["prime", "--hook"]),
    Rule("gc", ["prime", "--hook", "--hook-format", "codex"]),
    Rule("gc", ["handoff", "--auto"]),
    Rule("gc", ["handoff", "--auto", "context cycle"]),
    Rule("gc", ["nudge", "drain", "--inject"]),
    Rule("gc", ["mail", "check"], [], {"--inject": F()}),
    Rule("gc", ["mail", "inbox"], [], _J),
    Rule("gc", ["mail", "read"], [("id", 1, 1)], _J),
    Rule("gc", ["mail", "peek"], [("id", 1, 1)], _J),
    Rule("gc", ["mail", "archive"], [("id", 1, 20)]),
    Rule("gc", ["mail", "send"], [("word", 1, 1)], {"--subject": F("text", short="-s"), "--message": F("text", short="-m")}),
    Rule("gc", ["mail", "reply"], [("id", 1, 1)], {"--subject": F("text", short="-s"), "--message": F("text", short="-m")}),
    Rule("gc", ["session", "nudge"], [("word", 1, 1), ("line", 1, 50)], {"--delivery": F("delivery")}),
    Rule("gate-done", []),
]


def load_config(path: str) -> dict:
    try:
        raw = json.loads(Path(path).read_text())
        if not isinstance(raw, dict):  # (sem assert: `python -O` o apagaria)
            raise ValueError("a config tem que ser um objeto JSON")
    except (OSError, ValueError) as e:
        raise Refused(f"config ilegível ({path}): {e!r}")
    ok = {"city", "identity_pattern", "nudge_pattern", "gate_done_bin", "log", "timeout_s", "bin_dirs"}
    if set(raw) - ok or not {"city", "identity_pattern"} <= set(raw):
        raise Refused(f"config com chave desconhecida ou sem city/identity_pattern: {sorted(set(raw) ^ ok)[:8]}")
    home = pwd.getpwuid(os.getuid()).pw_dir
    cfg = {"gate_done_bin": None, "log": f"{home}/.gastown/logs/remote-shim.log", "timeout_s": 300,
           "bin_dirs": ["/opt/homebrew/bin", "/usr/local/bin", f"{home}/.local/bin", f"{home}/go/bin"], **raw}
    try:
        cfg["identity_re"] = re.compile(cfg["identity_pattern"])
        cfg["nudge_re"] = re.compile(cfg["nudge_pattern"]) if cfg.get("nudge_pattern") else None
    except (re.error, TypeError) as e:
        raise Refused(f"identity_pattern inválido: {e}")
    paths = [cfg["city"], cfg["log"]] + list(cfg["bin_dirs"]) + ([cfg["gate_done_bin"]] if cfg["gate_done_bin"] else [])
    if not all(isinstance(p, str) and os.path.isabs(p) for p in paths) or not os.path.isdir(cfg["city"]):
        raise Refused("config: city, log, bin_dirs e gate_done_bin têm que ser caminho absoluto, e city uma pasta")
    if not (isinstance(cfg["timeout_s"], int) and 1 <= cfg["timeout_s"] <= 3600):
        raise Refused("config: timeout_s entre 1 e 3600")
    cfg["home"] = home
    return cfg


def decode(raw: str | None) -> tuple[str, list[str], dict]:
    if not raw:
        raise Refused("sem comando: aqui não existe shell, só o protocolo rs1")
    if len(raw) > MAX_CMD:
        raise Refused("pedido grande demais")
    m = re.fullmatch(PROTO + r" ([A-Za-z0-9_-]+)", raw)
    if not m:
        raise Refused("pedido fora do formato `rs1 <base64url>`")

    def no_dups(pairs):
        d = dict(pairs)
        if len(d) != len(pairs):
            raise ValueError("chave duplicada")
        return d
    try:
        b = m.group(1)
        doc = json.loads(base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)).decode("utf-8"), object_pairs_hook=no_dups)
    except (ValueError, UnicodeError) as e:
        raise Refused(f"pedido ilegível: {e}")
    if not (isinstance(doc, dict) and set(doc) == {"tool", "argv", "env"} and isinstance(doc["tool"], str)
            and isinstance(doc["argv"], list) and isinstance(doc["env"], dict)):
        raise Refused("pedido com forma inesperada (esperado tool, argv, env)")
    if len(doc["argv"]) > MAX_ARGS or not all(isinstance(a, str) and "\0" not in a and len(a) <= MAX_TEXT and no_surrogate(a) for a in doc["argv"]):
        raise Refused("argv: mais de 64 itens, item que não é texto, com NUL, surrogate solto ou grande demais")
    if not all(isinstance(v, str) and no_surrogate(v) for v in doc["env"].values()):
        raise Refused("env: valor que não é texto (ou com surrogate solto)")
    return doc["tool"], doc["argv"], doc["env"]


def allowed_dirs(city: str) -> dict[str, str]:  # nome do rig → caminho real; "não consegui ler" levanta Refused, não vira "só a cidade"
    base = os.path.realpath(city)
    out = {".": base, os.path.basename(base): base}
    try:
        for line in (Path(base) / ".beads" / "routes.jsonl").read_text().splitlines():
            if line.strip():
                p = os.path.realpath(os.path.join(base, json.loads(line)["path"]))
                out[os.path.basename(p)] = p
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Refused(f"-C: não consegui ler .beads/routes.jsonl da cidade ({e!r}); sem ele não sei quais rigs existem")
    return out


def decide(cfg: dict, tool: str, argv: list[str], env: dict) -> tuple[Rule, list[str], str, dict]:
    """→ (regra, argv final sem o executável, cwd, ambiente identitário). Levanta Refused."""
    bad = [k for k in env if k not in ENV_VAL or not re.fullmatch(ENV_VAL[k], env[k])]
    if bad:
        raise Refused(f"env fora da lista ou fora do formato: {sorted(bad)[:4]}")
    alias = env.get("GC_ALIAS") or env.get("GC_AGENT")
    if not alias:
        raise Refused("sem GC_ALIAS/GC_AGENT: não executo sem saber quem pede")
    for k in ("GC_ALIAS", "GC_AGENT", "GC_SESSION_NAME", "GC_TEMPLATE"):  # tudo que diz QUEM é a sessão (o gc resolve handoff/drain/mail por elas)
        if k in env and not cfg["identity_re"].fullmatch(env[k]):
            raise Refused(f"{k} não casa com identity_pattern da config")
    cwd = os.path.realpath(cfg["city"])
    if tool == "bd" and argv[:1] == ["-C"]:
        if len(argv) < 2:
            raise Refused("-C sem valor")
        dirs = allowed_dirs(cfg["city"])
        d = dirs.get(argv[1]) or (os.path.realpath(argv[1]) if os.path.isabs(argv[1]) else None)
        if d not in dirs.values():
            raise Refused(f"-C: {argv[1][:60]!r} não é a cidade nem um rig da routes.jsonl")
        cwd, argv = d, argv[2:]
    cand = [r for r in RULES if r.tool == tool and list(r.words) == argv[:len(r.words)]]
    if not cand:
        raise Refused(f"comando fora da lista: {tool} {' '.join(a[:20] for a in argv[:2])}")
    reason = None
    for r in sorted(cand, key=lambda r: -len(r.words)):
        try:
            args = argv[len(r.words):]
            final = list(r.words) + r.apply(args)
            if r.words == ("session", "nudge") and not (cfg["nudge_re"] and cfg["nudge_re"].fullmatch(args[0])):
                raise Refused("alvo do nudge fora do nudge_pattern da config (sem a chave na config, nudge não roda)")
            return r, final, cwd, env
        except Refused as e:
            reason = reason or str(e)
    raise Refused(f"{tool} {' '.join(argv[:len(cand[0].words)])}: {reason}")


def audit(cfg: dict, *fields: str) -> None:
    p = Path(cfg["log"])
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    line = "\t".join(re.sub(r"[\t\r\n]", " ", f)[:200] for f in fields) + "\n"
    fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode("utf-8", "replace"))
    finally:
        os.close(fd)


def kill_group(p) -> None:  # o filho pode ter saído um instante antes: grupo que já não existe não é erro (nem vira "RECUSADO: erro interno" depois de ter rodado)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def serve(config: str) -> int:
    client = (os.environ.get("SSH_CLIENT", "").split() or ["?"])[0]
    client = client if re.fullmatch(r"[0-9A-Fa-f.:]{1,45}", client) else "?"
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cfg = None
    try:
        cfg = load_config(config)
        tool, argv, env = decode(os.environ.get("SSH_ORIGINAL_COMMAND"))
        rule, final, cwd, env = decide(cfg, tool, argv, env)
        alias = env.get("GC_ALIAS") or env.get("GC_AGENT")
        if tool == "gate-done":
            exe = cfg["gate_done_bin"]
            if not exe or not os.access(exe, os.X_OK):
                raise Refused("gate-done: nenhum executável configurado (gate_done_bin) no mini — ver runbook, pontos em aberto")
        else:
            exe = next((os.path.join(d, tool) for d in cfg["bin_dirs"] if os.access(os.path.join(d, tool), os.X_OK)), None)
            if not exe:
                raise Refused(f"{tool} não encontrado em {cfg['bin_dirs']}", NOTFOUND)
        try:
            audit(cfg, ts, client, alias, "ok", rule.label(), hashlib.sha256(json.dumps([tool, argv]).encode()).hexdigest()[:12])
        except OSError as e:
            raise Refused(f"não consegui gravar o log de auditoria ({e.strerror}); não executo sem rastro")
    except Refused as e:
        print(f"remote-shim-wrapper: RECUSADO: {e}", file=sys.stderr)
        if cfg:
            try:
                audit(cfg, ts, client, "?", "refused", str(e), "")
            except OSError:
                pass  # a recusa já saiu pelo stderr; o que não pode acontecer é executar sem rastro, e aqui nada executa
        return e.rc
    home, user = cfg["home"], pwd.getpwuid(os.getuid()).pw_name
    child = {"HOME": home, "USER": user, "LOGNAME": user, "LANG": "en_US.UTF-8",
             "PATH": ":".join(cfg["bin_dirs"] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]), "BEADS_ACTOR": alias, **env}
    t0 = time.time()
    try:
        p = subprocess.Popen([exe] + final, cwd=cwd, env=child, start_new_session=True)
    except OSError as e:
        print(f"remote-shim-wrapper: não consegui executar {tool}: {e.strerror}", file=sys.stderr)
        return NOEXEC

    def die(sig, _frame):  # o cliente ssh foi embora: o filho não pode sobreviver sozinho (ele está numa sessão própria)
        kill_group(p)
        os._exit(128 + sig)
    for s in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(s, die)
    try:
        rc = p.wait(timeout=cfg["timeout_s"])
    except subprocess.TimeoutExpired:
        kill_group(p)
        p.wait()
        rc = TIMEOUT
        print(f"remote-shim-wrapper: {tool} passou de {cfg['timeout_s']}s e foi encerrado", file=sys.stderr)
    rc = 128 - rc if rc < 0 else rc
    try:
        audit(cfg, ts, client, alias, f"done rc={rc}", rule.label(), f"{time.time() - t0:.1f}s")
    except OSError as e:  # o comando já rodou e a linha `ok` está no log; o que falta é o desfecho, e isso é dito em vez de calado
        print(f"remote-shim-wrapper: aviso: o comando terminou (rc={rc}) mas não consegui gravar o desfecho no log ({e.strerror})", file=sys.stderr)
    return rc


def authorized_line(config: str, pubkey: str, frm: str | None) -> str:
    load_config(config)  # a linha só nasce de uma config que o próprio wrapper aceitaria
    lines = [x for x in Path(pubkey).read_text().splitlines() if x.strip()]
    parts = lines[0].split() if len(lines) == 1 else []  # duas chaves, ou um blob quebrado em duas linhas, não é "uma chave"
    if len(parts) < 2 or not re.fullmatch(r"ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com", parts[0]) \
            or not re.fullmatch(r"[A-Za-z0-9+/=]+", parts[1]):
        raise Refused("pubkey: esperado UMA chave pública sem opções na frente (tipo + base64 [+ comentário])")
    if frm is not None and not re.fullmatch(r"[0-9A-Za-z.:,/*?!-]{1,200}", frm):
        raise Refused("--from: só endereços, CIDR ou curinga, sem aspas nem espaço")
    cmd = " ".join(shlex.quote(x) for x in [sys.executable, "-I", os.path.realpath(__file__), "serve", "--config", os.path.realpath(config)])
    opts = ["restrict"] + ([f'from="{frm}"'] if frm else []) + ['command="' + cmd.replace("\\", "\\\\").replace('"', '\\"') + '"']
    return f"{','.join(opts)} {parts[0]} {parts[1]} remote-shim-hetzner"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="remote-shim-wrapper.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve").add_argument("--config", required=True)
    sub.add_parser("list")
    a = sub.add_parser("authorized-line")
    a.add_argument("--config", required=True)
    a.add_argument("--pubkey", required=True)
    a.add_argument("--from", dest="frm")
    n = ap.parse_args(argv)
    if n.cmd == "serve":
        try:
            return serve(n.config)
        except Exception as e:  # nunca cair para "executar" por causa de um erro que não previ
            print(f"remote-shim-wrapper: RECUSADO: erro interno {type(e).__name__}: {e}", file=sys.stderr)
            return REFUSED
    if n.cmd == "list":
        print("\n".join(r.label() for r in RULES))
        print("\n".join("env " + k for k in sorted(ENV_VAL)))
        return 0
    try:
        print(authorized_line(n.config, n.pubkey, n.frm))
    except (Refused, OSError) as e:
        print(f"remote-shim-wrapper: RECUSADO: {e}", file=sys.stderr)
        return REFUSED
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
