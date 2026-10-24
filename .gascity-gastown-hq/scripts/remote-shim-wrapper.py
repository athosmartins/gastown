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
  TRAVA DE DONO (`+dono` na lista; ga-2hd02v.1.16): `bd comment` e `bd close` leem a bead antes (`bd show <id> --json`, mesmo cwd e ambiente, BD_READONLY=true) e, se ela
  tem o rótulo `type:quality-gate-verdict`, só passam quando o assignee é o alias declarado da sessão (o dispatcher lê o `VERDICT:` dos comentários dela, PASS antes de FAIL: uma sessão
  do nó que comentasse na bead de um revisor morto forjaria o veredito). Bead sem esse rótulo passa como antes. Leitura que falhou ou veio fora da forma = recusa (77, "nada foi executado, pode repetir").
  DEVOLVER A BEAD (ga-dxszii): `bd update <id> --if-assignee <alias> --if-status in_progress --assignee '' --status open --add-label node:never [--remove-label <rótulo do despacho>]...`.
  Cada flag leva o valor EXATO (F(lit=…)); `<alias>` tem que ser o da sessão (Rule.apply); só na cidade (`city_only`); a guarda de dono é o compare-and-swap do próprio bd, então o wrapper
  NÃO lê a bead antes. É a ÚNICA forma de `bd` da lista que muda dono ou rótulo e o único `bd update` que muda status (o `bd close` fecha por outro caminho; o `gate-done` solta a bead por conta própria, no mini). Um pedido que nenhuma forma de um comando aceita é
  recusado com o motivo de CADA forma (decide), não só o da primeira.

POR QUE RECUSA EM VEZ DE ADAPTAR (está na lista / não está / não consegui saber — o último não vira "está")
  Config ilegível, routes.jsonl ilegível, log de auditoria que não grava, identidade fora do padrão, ferramenta que não achei → não executa.
  A requisição é registrada (hash do argv, nunca o texto; uma RECUSA grava o motivo, que pode citar até 60 caracteres do argumento) ANTES de rodar; sem rastro não há execução.
  Todo pedido que chegou a decidir "roda" fecha o log com uma linha `done …` (rc=N, nao-iniciado, killed sig=N filho-encerrado|filho-nao-encerrado|sem-filho-registrado, unknown): a linha `ok` sozinha não quer dizer "rodou".
  A `ok` e a `done` do mesmo pedido levam o mesmo ts e a mesma hash do argv: é assim que se pareiam. Um sinal que chega DENTRO do Popen (o filho já pode existir, ainda não registrado) é anotado e
  reenviado quando o filho estiver registrado, e aí o grupo é encerrado: `sem-filho-registrado` só existe quando o Popen nem começou.
  Depois que o filho existe NADA vira "RECUSADO": falha do próprio wrapper nessa fase sai 125 ("iniciado, desfecho desconhecido"), porque quem lê 77 repete o pedido.

SUBCOMANDOS
  serve --config CONF                    forced-command (SSH_ORIGINAL_COMMAND na entrada)
  list                                   imprime a lista permitida (regras e variáveis de ambiente)
  authorized-line --config CONF --pubkey ARQ.pub [--from CIDR[,CIDR]]   imprime a linha do authorized_keys; NÃO grava nada (sem --from avisa no stderr: a chave valeria de qualquer endereço)

CONFIG (JSON): {"city": "/abs", "identity_pattern": "regex", "nudge_pattern": "regex", "gate_done_bin": "/abs"|null, "log": "/abs", "timeout_s": 300, "bin_dirs": ["/abs"]}
  Só `city` e `identity_pattern` são obrigatórios (sem `nudge_pattern` o nudge é recusado); chave desconhecida é erro.

CÓDIGOS: o do comando executado · 77 recusado (nada executou) · 124 estourou timeout_s · 125 o comando FOI iniciado e o wrapper falhou antes de saber o desfecho (pode ter rodado) ·
  126 não consegui executar · 127 ferramenta não encontrada · 2 uso. O código do próprio comando pode coincidir com estes; o stderr (`remote-shim-wrapper: …`) e o log dizem de quem é.
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

REFUSED, TIMEOUT, UNKNOWN, NOEXEC, NOTFOUND = 77, 124, 125, 126, 127
_STARTED: list = []  # o filho, assim que o Popen o devolve: o handler de sinal e o último catch-all precisam achá-lo (e saber que, daqui em diante, nada é "recusado")
# `on`: o Popen está em curso. O filho já pode existir (o fork/exec inteiro acontece dentro do Popen) e _STARTED ainda não o tem; nesse intervalo o handler de sinal NÃO
# age (não há o que encerrar e dizer "sem filho" seria falso): guarda o sinal em `sig` e o serve() o reenvia quando o filho estiver registrado.
_LAUNCH: dict = {"on": False, "sig": None}
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


ID = r"[A-Za-z][A-Za-z0-9]{0,15}(?:-[A-Za-z0-9]{1,16}){1,2}(?:\.[0-9]{1,4}){0,3}"  # 2 hífens são os wisps/mails reais (ga-wisp-0i6hr: 653/653 medidos em 14/10); 3 ou mais não existem


def v_text(s: str) -> bool:
    return 0 < len(s) <= MAX_TEXT and "\0" not in s


def no_surrogate(s: str) -> bool:  # surrogate solto vira byte cru (0x80-0xFF) no argv do filho, e v_line não o enxerga
    return re.search(r"[\ud800-\udfff]", s) is None


# um só conjunto para o que NÃO pode chegar ao terminal de outra sessão nem ao log: controle C0/C1 (TAB, ESC, CR e LF inclusive), separador de linha Unicode e toda
# marca/controle bidi (LRM/RLM U+200E-F, ALM U+061C, embeddings/overrides U+202A-E, isolates U+2066-9): mudam o que se VÊ sem mudar o que foi digitado
CTRL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]")


def v_line(s: str) -> bool:  # texto que vira digitação no terminal de OUTRA sessão
    return v_text(s) and not CTRL.search(s)


def v_kv(s: str) -> bool:
    k, sep, val = s.partition("=")
    return bool(sep) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]{0,63}", k) is not None \
        and k.startswith(ALLOW_META) and len(val) <= 4000 and "\0" not in val


def v_ref(s: str) -> bool:  # nome de branch do espelho (gate-done <bead> <ref> <sha>): a forma já exclui `:`/`@`/espaço; aqui saem também `..`, `//` e o final `/`, `.` ou `.lock` (só os casos comuns: o executável confere o resto com `git check-ref-format`)
    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}", s) is not None and ".." not in s and "//" not in s and not s.endswith(("/", ".", ".lock"))


def v_n(s: str) -> bool:  # --limit 0 é "tudo": varredura de beads inteiros não sai do mini
    return re.fullmatch(r"[1-9][0-9]{0,2}", s) is not None and int(s) <= 200


VAL = {"id": _fm(ID), "ids": _fm(ID + "(?:," + ID + "){0,49}"), "word": _fm(r"[A-Za-z0-9][A-Za-z0-9._:@/-]{0,79}"),
       "status": _fm(r"[a-z_]{1,20}(?:,[a-z_]{1,20}){0,5}"), "kv": v_kv, "text": v_text, "line": v_line, "n": v_n,
       "delivery": _fm(r"wait-idle|queue"),
       # gate-done <bead> <ref> <sha> (ga-2hd02v.1.18): o ref é nome de branch do espelho (começa por letra/dígito: nunca vira flag; sem `:` nem `@`); o sha é inteiro, 40 hex
       "ref": v_ref, "sha": _fm(r"[0-9a-f]{40}")}
_IDENT = r"[A-Za-z0-9][A-Za-z0-9._@/-]{0,95}"
VAL["alias"] = _fm(_IDENT)  # o formato de um alias (o MESMO que o env aceita); quem o confere contra a sessão é Rule.apply
# única entrada de ambiente aceita do cliente (e o valor tem formato): o servidor declara QUEM é a sessão, nada que aponte caminho
ENV_VAL = {"GC_AGENT": _IDENT, "GC_ALIAS": _IDENT, "GC_SESSION_NAME": _IDENT, "GC_TEMPLATE": _IDENT,
           "GC_SESSION_ORIGIN": r"[a-z]{1,20}", "GC_MANAGED_SESSION_HOOK": r"1", "GC_HOOK_EVENT_NAME": r"[A-Za-z]{1,30}"}


class F:  # uma flag: val = nome em VAL (ou None se não leva valor), lit = os valores LITERAIS que ela aceita (no lugar de val), rep = pode repetir, req = obrigatória, short = apelido curto
    def __init__(self, val=None, rep=False, req=False, short=None, lit=None):
        self.val, self.rep, self.req, self.short, self.lit = ("lit" if lit is not None else val), rep, req, short, lit

    def ok(self, s: str) -> bool:
        return s in self.lit if self.lit is not None else VAL[self.val](s)

    def fmt(self) -> str:  # como o `list` e a recusa mostram o valor: um literal como está (o vazio vira ''), vários como <a|b|c>, o resto pelo nome do formato
        if self.lit is None:
            return f"<{self.val}>"
        return shlex.quote(self.lit[0]) if len(self.lit) == 1 else "<" + "|".join(self.lit) + ">"


class Rule:
    def __init__(self, tool, words, pos=(), flags=None, owner_lock=False, hint="", city_only=False):
        self.tool, self.words, self.pos, self.flags = tool, tuple(words), list(pos), dict(flags or {})
        self.short = {f.short: n for n, f in self.flags.items() if f.short}
        self.owner_lock = owner_lock  # escreve na bead <id>: em bead de veredito (VERDICT_LABEL) só passa para o dono (owner_gate); o serve() lê o estado antes
        self.hint = f" (forma: {hint})" if hint else ""  # só entra na recusa por contagem de posicionais: a mensagem diz a forma inteira, não só o 1º grupo que faltou
        self.city_only = city_only  # só vale na cidade (sem -C, ou -C . / o nome da cidade): bead de rig fica de fora (decide)

    def label(self) -> str:  # a linha que o runbook mostra: gerada da regra, então não há duas verdades
        w = " ".join(shlex.quote(x) if " " in x else x for x in self.words)
        s = [self.tool + (" [-C .]" if self.city_only else " [-C <rig>]" if self.tool == "bd" else ""), w] if w else [self.tool]
        for val, lo, hi in self.pos:
            s.append(f"<{val}>" + ("..." if hi > 1 else ""))
        for n, f in self.flags.items():
            nm = n + (f"|{f.short}" if f.short else "") + (f" {'<key=value>' if f.val == 'kv' else f.fmt()}" if f.val else "")
            s.append((nm if f.req else f"[{nm}]") + ("..." if f.rep else ""))
        return " ".join(s) + (" +dono" if self.owner_lock else "")

    def apply(self, args: list[str], alias: str | None = None) -> tuple[list[str], list[str]]:
        """Recebe o argv depois das palavras fixas; devolve (argumentos a executar na ORDEM do cliente, flags curtas viram longas; só os posicionais, na ordem) ou levanta Refused.
        `alias` é o da sessão: a flag do tipo <alias> só vale com ELE (sem alias para conferir recusa: "não sei quem pede" nunca vira "é você")."""
        out, pos, seen, i, dd, after_dd = [], [], set(), 0, False, 0
        while i < len(args):
            a = args[i]
            if dd or not a.startswith("-") or a == "-":
                pos.append(a)
                out.append(a)
                after_dd += dd
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
                    if i + 1 >= len(args) or not f.ok(args[i + 1]):
                        raise Refused(f"{name} sem valor ou com valor fora do formato {f.fmt()}")
                    if f.val == "alias" and args[i + 1] != alias:  # tem o formato de um alias, mas tem que ser o DESTA sessão: o compare-and-swap do bd só guarda se o valor for o dono de verdade
                        raise Refused(f"{name} tem que ser o alias desta sessão ({(alias or '?')[:60]!r}): só se devolve a PRÓPRIA bead")
                    out += [name, args[i + 1]]
                    i += 2
        if dd and not after_dd:  # `--` sem nada depois não é "forma EXATA": o executável receberia argc=1 argv=[--] (o gate-done é um script, não um cobra que o absorve)
            raise Refused("`--` sem nada depois")
        for n, f in self.flags.items():
            if f.req and n not in seen:
                raise Refused(f"falta {n}")
        p = 0
        for gi, (val, lo, hi) in enumerate(self.pos):
            take = min(hi, len(pos) - p - sum(g[1] for g in self.pos[gi + 1:]))
            if take < lo:
                raise Refused(f"faltam argumentos <{val}>{self.hint}")
            for tok in pos[p:p + take]:
                if not VAL[val](tok):
                    raise Refused(f"argumento fora do formato <{val}>")
            p += take
        if p != len(pos):
            raise Refused(f"argumento a mais{self.hint}")
        return out, pos


_J = {"--json": F()}
DISPATCH_LABELS = ("pilot:dispatched", "pilot:dispatching", "story:in-flight")  # o que o Pilot grava ao despachar a bead a um dog: devolvê-la tira estes e só estes
RULES = [
    Rule("bd", ["show"], [("id", 1, 1)], _J),
    Rule("bd", ["list"], [], {**_J, "--status": F("status", short="-s"), "--assignee": F("word", short="-a"),
                              "--label": F("word", rep=True, short="-l"), "--parent": F("id"), "--limit": F("n", short="-n"),
                              "--id": F("ids")}),
    Rule("bd", ["update"], [("id", 1, 1)], {**_J, "--set-metadata": F("kv", rep=True, req=True)}),
    # ga-dxszii: o dog do nó DEVOLVE ao mini a bead que não pode construir (ela só roda lá), numa escrita só e guardada pelo próprio bd: --if-assignee = o alias DESTA sessão e --if-status
    # in_progress (compare-and-swap: sem ler antes, então sem janela), dono vazio, status open, o veto node:never (sem ele o Pilot a manda de volta ao nó a cada varredura) e, se quiser, os rótulos
    # do despacho. Cada flag tem o valor EXATO; nada mais passa (metadata, outro rótulo, outro status). Só na cidade: o veto node:never é do HQ. Fica DEPOIS da regra de --set-metadata: na recusa
    # de um pedido torto o motivo daquela vem primeiro e o desta vem junto (decide), com a forma inteira
    Rule("bd", ["update"], [("id", 1, 1)], {**_J, "--if-assignee": F("alias", req=True), "--if-status": F(lit=("in_progress",), req=True), "--assignee": F(lit=("",), req=True),
                                           "--status": F(lit=("open",), req=True), "--add-label": F(lit=("node:never",), req=True), "--remove-label": F(lit=DISPATCH_LABELS, rep=True)},
         city_only=True),
    Rule("bd", ["comment"], [("id", 1, 1), ("text", 1, 50)], {}, owner_lock=True),
    Rule("bd", ["comment"], [("id", 1, 1)], {"--stdin": F(req=True)}, owner_lock=True),
    Rule("bd", ["close"], [("id", 1, 1)], {**_J, "--reason": F("text", short="-r")}, owner_lock=True),
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
    # a forma com argumentos vem ANTES da sem argumento: a recusa de 1 ou 2 argumentos (a 1ª regra que falha dá o motivo) diz a forma inteira. Sem argumento cai na regra de baixo
    Rule("gate-done", [], [("id", 1, 1), ("ref", 1, 1), ("sha", 1, 1)], hint="gate-done <bead> <ref> <sha>, ou gate-done sem argumento"),
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
    unknown, missing = sorted(set(raw) - ok), sorted({"city", "identity_pattern"} - set(raw))
    if unknown or missing:
        raise Refused("config: " + "; ".join(([f"chave desconhecida {unknown[:8]}"] if unknown else []) + ([f"sem city/identity_pattern, falta {missing}"] if missing else [])))
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
    if not (type(cfg["timeout_s"]) is int and 1 <= cfg["timeout_s"] <= 3600):  # (type, não isinstance: o JSON `true` é int em Python e viraria 1 s)
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
    except (ValueError, UnicodeError, RecursionError) as e:  # (JSON aninhado fundo estoura a pilha dentro do teto de tamanho)
        raise Refused(f"pedido ilegível: {type(e).__name__}: {str(e)[:80]}")
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
    reasons = []  # (regra, motivo) de cada forma que NÃO serviu
    for r in sorted(cand, key=lambda r: -len(r.words)):
        try:
            args = argv[len(r.words):]
            out, pos = r.apply(args, alias)
            final = list(r.words) + out
            if r.city_only and cwd != os.path.realpath(cfg["city"]):
                raise Refused("esta forma só vale na cidade (sem -C, ou -C .): bead de rig fica de fora")
            if r.words == ("session", "nudge") and not (cfg["nudge_re"] and cfg["nudge_re"].fullmatch(pos[0])):  # pos[0] é o alvo que o gc usa; args[0] podia ser uma flag
                raise Refused("alvo do nudge fora do nudge_pattern da config (sem a chave na config, nudge não roda)")
            return r, final, cwd, env
        except Refused as e:
            reasons.append((r, str(e)))
    # o motivo da 1ª forma vem primeiro, como sempre; as outras formas que falharam por OUTRO motivo vêm junto, com a forma inteira: quem tentou uma receita incompleta (--status open --assignee '')
    # lê o que falta e a forma certa, em vez de só o "flag fora da lista" da regra de --set-metadata, que a rejeita na 1ª flag e esconde que existe outra forma (ga-dxszii)
    others = "".join(f" | ou, em outra forma da lista, {r.label()}: {why}" for r, why in reasons[1:] if why != reasons[0][1])
    raise Refused(f"{tool} {' '.join(argv[:len(cand[0].words)])}: {reasons[0][1]}{others}")


LOG_BAD = CTRL  # o MESMO objeto que o v_line usa: não há duas listas para divergir


def audit(cfg: dict, *fields: str) -> None:
    p = Path(cfg["log"])
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    line = "\t".join(LOG_BAD.sub("?", f)[:200] for f in fields) + "\n"  # TODOS os campos: o alias/argumento declarado pelo cliente entra em recusas, e ESC ou bidi num log lido no terminal o reescreve
    fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode("utf-8", "replace"))
    finally:
        os.close(fd)


def say(msg: str) -> None:  # stderr pode já ter fechado (o cliente ssh foi embora): avisar é melhor esforço e nunca muda o desfecho
    try:
        print(f"remote-shim-wrapper: {msg}", file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass


def kill_group(p) -> None:  # o filho pode ter saído um instante antes: isso não é erro (nem vira "RECUSADO" depois de ter rodado)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:  # o grupo já não existe (filho já reapado)
        pass
    except PermissionError:  # macOS: grupo cujo único membro já saiu e ainda não foi reapado dá EPERM, não ESRCH
        if p.poll() is None:  # (o poll reapa) e o filho continua VIVO: não consegui matá-lo — isso não é a corrida, e tem que aparecer
            raise


def who_declared(env: dict | None) -> str:  # quem o pedido DIZ ser (declaração, não prova): `?` nem decodificou, `sem-alias` decodificou e não trouxe
    alias = (env or {}).get("GC_ALIAS") or (env or {}).get("GC_AGENT")
    return "?" if env is None else f"declarado={alias[:60]}" if alias else "sem-alias"


def end_children() -> str:  # encerra o grupo do filho e diz o que de fato aconteceu: um kill que levantou NÃO é "encerrado"
    if not _STARTED:
        return "sem-filho-registrado"  # verdade porque o handler de sinal só chega aqui FORA do Popen (ver _LAUNCH): sem filho registrado quer dizer que o Popen ainda nem começou
    try:
        for p in _STARTED:
            kill_group(p)
    except Exception:
        return "filho-nao-encerrado"
    return "filho-encerrado"


VERDICT_LABEL = "type:quality-gate-verdict"  # a bead de veredito do revisor do gate: o dispatcher lê o `VERDICT:` dos comentários dela (PASS antes de FAIL), então quem escreve nela decide o merge
OWNER_READ_S = 60  # teto da leitura de estado (min com timeout_s); o prazo do comando em si continua só do comando


def read_bead(exe: str, cwd: str, child: dict, bead: str, timeout_s: float) -> dict:
    """`bd show <id> --json` no MESMO cwd e ambiente do comando que vem depois → o dict da bead. Levanta Refused ("nada foi executado, pode repetir")
    quando não consegui ler: não executou, rc≠0, prazo, stdout que não é uma lista de UMA bead. Lê SÓ o stdout (o Dolt joga `[mysql] … i/o timeout` no stderr com o JSON limpo).
    Roda com BD_READONLY=true + BD_DOLT_AUTO_COMMIT=off (a convenção do engine para leitura: não auto-comita) e stdin fechado (o texto do `bd comment --stdin` é do COMANDO, não da leitura)."""
    again = "nada foi executado, pode repetir"
    env = {**child, "BD_READONLY": "true", "BD_DOLT_AUTO_COMMIT": "off"}
    try:
        p = subprocess.Popen([exe, "show", bead, "--json"], cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        raise Refused(f"não consegui ler o estado de {bead} (bd show não executou: {e.strerror}); {again}")
    try:
        out, _ = p.communicate(timeout=min(timeout_s, OWNER_READ_S))
    except subprocess.TimeoutExpired:
        kill_group(p)
        p.communicate()  # reapa; com o grupo morto o pipe fecha
        raise Refused(f"não consegui ler o estado de {bead} (bd show passou do prazo); {again}")
    except BaseException:  # qualquer outra saída (sinal, erro interno): a leitura não pode sobreviver ao pedido
        kill_group(p)
        raise
    if p.returncode != 0:
        raise Refused(f"não consegui ler o estado de {bead} (bd show saiu com rc={p.returncode}); {again}")
    try:
        data = json.loads(out)
    except ValueError:
        raise Refused(f"não consegui ler o estado de {bead} (a resposta do bd show não é JSON); {again}")
    if not (isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict)):
        raise Refused(f"não consegui ler o estado de {bead} (a resposta do bd show não é uma lista de uma bead); {again}")
    return data[0]


def owner_gate(state: dict, bead: str, alias: str) -> None:
    """A trava de DONO (ga-2hd02v.1.16): bd comment/close em bead de veredito só passa se o assignee for o alias declarado da sessão. Três estados:
    tem (rótulo/dono lidos) · não tem (a chave AUSENTE: o bd a omite quando não há — 55 de 60 beads fechadas não têm `assignee`) · não consegui ler (tipo errado: nunca vira "não tem")."""
    labels = state.get("labels", [])
    if not (isinstance(labels, list) and all(isinstance(x, str) for x in labels)):
        raise Refused(f"não consegui ler o estado de {bead} (labels fora do formato); nada foi executado, pode repetir")
    owner = state.get("assignee", "")
    if not isinstance(owner, str):  # null, número, lista: o bd não escreve isso; ler como "sem dono" liberaria o comando por um dado que não entendi
        raise Refused(f"não consegui ler o estado de {bead} (assignee fora do formato); nada foi executado, pode repetir")
    if VERDICT_LABEL in labels and owner != alias:  # (alias nunca é vazio: o decide() recusa sem ele; então "sem dono" também recusa)
        raise Refused(f"{bead} é bead de veredito ({VERDICT_LABEL}) de {owner[:60]!r}, não de {alias[:60]!r}: bd comment/close nela só o dono faz; não repita")


def serve(config: str) -> int:
    client = (os.environ.get("SSH_CLIENT", "").split() or ["?"])[0]
    client = client if re.fullmatch(r"[0-9A-Fa-f.:]{1,45}", client) else "?"
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cfg = declared = None
    try:
        cfg = load_config(config)
        tool, argv, env = decode(os.environ.get("SSH_ORIGINAL_COMMAND"))
        declared = env
        rule, final, cwd, env = decide(cfg, tool, argv, env)
        alias = env.get("GC_ALIAS") or env.get("GC_AGENT")
        if tool == "gate-done":
            exe = cfg["gate_done_bin"]
            if not exe:
                raise Refused("gate-done: nenhum executável configurado (gate_done_bin) no mini — ver runbook, pontos em aberto")
            if not os.access(exe, os.X_OK):
                raise Refused(f"gate-done: gate_done_bin está configurado ({exe[:60]!r}) mas não é um executável")
        else:
            exe = next((os.path.join(d, tool) for d in cfg["bin_dirs"] if os.access(os.path.join(d, tool), os.X_OK)), None)
            if not exe:
                raise Refused(f"{tool} não encontrado em {cfg['bin_dirs']}", NOTFOUND)
        home, user = cfg["home"], pwd.getpwuid(os.getuid()).pw_name
        child = {"HOME": home, "USER": user, "LOGNAME": user, "LANG": "en_US.UTF-8",
                 "PATH": ":".join(cfg["bin_dirs"] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]), "BEADS_ACTOR": alias, **env}
        if rule.owner_lock:  # antes de gravar o `ok`: recusa por dono ou por leitura que falhou não executa nada, e fica no log como `refused`
            bead = rule.apply(final[len(rule.words):], alias)[1][0]  # o <id> (a 1ª posicional; `bd close --reason x <id>` tem flag antes dele em `final`)
            owner_gate(read_bead(exe, cwd, child, bead, cfg["timeout_s"]), bead, alias)
        t0 = time.time()
        rid = hashlib.sha256(json.dumps([tool, argv]).encode()).hexdigest()[:12]  # a linha `ok` e a `done` do mesmo pedido levam o mesmo ts e esta hash: é assim que se pareiam

        def outcome(what: str) -> None:  # a linha de desfecho: dizer que não gravou é melhor que calar (a linha `ok` sozinha seria lida como "rodou")
            try:
                audit(cfg, ts, client, alias, what, rule.label(), f"{time.time() - t0:.1f}s", rid)
            except OSError as e:
                say(f"aviso: não consegui gravar o desfecho ({what}) no log ({e.strerror})")

        def die(sig, _frame):  # o cliente ssh foi embora: o filho não pode sobreviver sozinho (ele está numa sessão própria)
            if _LAUNCH["on"]:  # Popen em curso: o filho pode já existir (o fork/exec inteiro roda lá dentro) e ainda não estar em _STARTED. Agir agora não mataria nada e o log diria "sem filho" com o comando rodando
                _LAUNCH["sig"] = _LAUNCH["sig"] or sig  # (não uso máscara de sinal em volta do Popen: o filho a herdaria bloqueada e o bd/gc rodaria sem poder receber SIGTERM)
                return
            outcome(f"done killed sig={sig} {end_children()}")
            os._exit(128 + sig)
        for s in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):  # antes do Popen: depois dele a janela com o filho vivo e sem handler seria a do wait inteiro
            signal.signal(s, die)
        try:
            audit(cfg, ts, client, alias, "ok", rule.label(), rid)
        except OSError as e:
            raise Refused(f"não consegui gravar o log de auditoria ({e.strerror}); não executo sem rastro")
    except Exception as e:  # Refused é o caso normal; um erro que não previ, ainda ANTES do Popen, também não executa nada — e também fica no log
        r = e if isinstance(e, Refused) else Refused(f"erro interno {type(e).__name__}: {e}")
        say(f"RECUSADO: {r}")
        if cfg:
            try:
                audit(cfg, ts, client, who_declared(declared), "refused", str(r), "")
            except OSError:
                pass  # a recusa já saiu pelo stderr; o que não pode acontecer é executar sem rastro, e aqui nada executa
        return r.rc
    # daqui em diante o comando vai começar (ou já começou): nada abaixo pode virar "RECUSADO", que quem chama leria como "nada executou"
    _LAUNCH["on"] = True  # de agora até o filho estar em _STARTED um sinal só é anotado (ver die)
    try:
        _STARTED.append(subprocess.Popen([exe] + final, cwd=cwd, env=child, start_new_session=True))
    except OSError as e:
        _LAUNCH["on"] = False  # o exec falhou: não há filho, e um sinal volta a ter o tratamento normal
        say(f"não consegui executar {tool}: {e.strerror}")
        outcome(f"done rc={NOEXEC} nao-iniciado")
        return NOEXEC
    except Exception as e:  # algo que não é OSError saiu do Popen: não sei se o filho nasceu, e sem o handle não posso encerrá-lo. `on` fica ligado de propósito: um sinal daqui até a saída é anotado e NÃO reenviado (nada a encerrar), em vez de o log dizer "sem filho"
        say(f"ATENÇÃO: {tool} pode ter sido iniciado (o Popen levantou {type(e).__name__}: {e}); desfecho desconhecido — não repita às cegas")
        outcome(f"done unknown {type(e).__name__}")
        return UNKNOWN
    _LAUNCH["on"] = False
    if _LAUNCH["sig"]:  # um sinal chegou durante o Popen: com o filho registrado o handler o encerra e diz a verdade (o comando começou e o grupo foi encerrado)
        die(_LAUNCH["sig"], None)
    p = _STARTED[0]
    try:
        try:
            rc = p.wait(timeout=cfg["timeout_s"])
        except subprocess.TimeoutExpired:
            rc = p.poll()  # o filho pode ter saído entre o último poll do wait e o prazo: terminou sozinho, não estourou
            if rc is None:
                kill_group(p)
                rc = p.wait()
                if rc == -signal.SIGKILL:  # morreu do NOSSO kill: estourou o prazo. Outro código é de um filho que saiu sozinho entre o poll e o kill, e vale o código dele
                    rc = TIMEOUT
                    say(f"{tool} passou de {cfg['timeout_s']}s e foi encerrado")
        rc = 128 - rc if rc < 0 else rc
    except Exception as e:  # o comando JÁ foi iniciado e pode ter feito efeito: o desfecho é desconhecido, e dizer "recusado" faria o cliente repetir
        ended = end_children() == "filho-encerrado"
        say(f"ATENÇÃO: {tool} FOI INICIADO e o wrapper falhou depois ({type(e).__name__}: {e}); o comando pode ter rodado e "
            + ("o grupo foi encerrado" if ended else "eu NÃO consegui encerrar o grupo: ele pode seguir rodando") + " — não repita às cegas")
        outcome(f"done unknown {type(e).__name__}" + ("" if ended else " filho-nao-encerrado"))
        return UNKNOWN
    outcome(f"done rc={rc}")
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
    if frm is None:  # a linha sai igual, mas vale de QUALQUER endereço: fail-open que antes não dizia nada
        say("AVISO: sem --from a chave vale a partir de QUALQUER endereço (restrict e command= continuam valendo); use --from <ip do servidor ou do túnel>")
    cmd = " ".join(shlex.quote(x) for x in [sys.executable, "-I", os.path.realpath(__file__), "serve", "--config", os.path.realpath(config)])
    if re.search(r"[\x00-\x1f\x7f]", cmd):  # uma quebra de linha no caminho viraria uma SEGUNDA linha (outra chave, outras opções) no authorized_keys
        raise Refused("caminho (python, wrapper ou config) com caractere de controle: não vai para o authorized_keys")
    # o sshd (opt_dequote) só desfaz `\\"` dentro de command="…": dobrar a barra invertida a entregaria dobrada ao shell, e o wrapper não acharia a config (medido num sshd real)
    opts = ["restrict"] + ([f'from="{frm}"'] if frm else []) + ['command="' + cmd.replace('"', '\\"') + '"']
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
        except Exception as e:  # serve() já cobre os dois lados do Popen; esta é a última rede, e conta o estado verdadeiro: com o filho vivo (ou o Popen em curso) nunca diz "RECUSADO"
            if _STARTED or _LAUNCH["on"]:
                say(f"ATENÇÃO: o comando FOI INICIADO e o wrapper falhou depois ({type(e).__name__}: {e}); pode ter rodado — não repita às cegas")
                return UNKNOWN
            say(f"RECUSADO: erro interno {type(e).__name__}: {e}")
            return REFUSED
    if n.cmd == "list":
        print("\n".join(r.label() for r in RULES))
        print("\n".join("env " + k for k in sorted(ENV_VAL)))
        return 0
    try:
        print(authorized_line(n.config, n.pubkey, n.frm))
    except (Refused, OSError) as e:
        say(f"RECUSADO: {e}")
        return REFUSED
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
