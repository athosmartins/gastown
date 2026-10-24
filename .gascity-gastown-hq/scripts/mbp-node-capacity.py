#!/usr/bin/env python3
"""mbp-node-capacity.py — o oráculo de capacidade do MBP, no contrato que o wa-node-dispatch.sh lê do hetzner-capacity.py (ga-w7qwl1.2.1).

Contents
  Contrato · O que decide · Três estados · Env (teste)

CONTRATO  O wa-node-dispatch.sh (modo pilot) roda `python3 -I mbp-node-capacity.py --json verdict` com a entrada fechada e um prazo (45 s) e lê UM JSON:
  exit 0  {"verdict": "node", "free": N >= 1, ...}   o MBP recebe mais uma sessão agora
  exit 1  {"verdict": "local", "reason": ...}        recusa clara: a bead fica no mini
  exit 2  {"verdict": "unknown", "reason": ...}      não consegui saber: a bead fica no mini (o despachante lê como 11)
  Qualquer outra coisa (prazo, traceback, JSON ruim, `free` que não é número >= 1 num `node`) o despachante também lê como "não sei". Só exit 0 + `node` autoriza.

O QUE DECIDE  Duas leituras, em paralelo (cabem no prazo de 45 s do despachante): (1) `gc-session-ssh gate mbp`, o MESMO veredito que o start do provider aplica (bandeira, pausa do Athos, presença, saúde, slot_cap): este oráculo
  não tem regra de presença própria, para não haver duas regras que discordem; (2) `gc session list --json`, as sessões do MBP que o engine vê (template wa-worker-remote-mbp, ou nome/alias com `-remote-mbp-`).
  Vagas = min(cap do host, slot_cap) − vivas; fechada ou dormindo não ocupa e estado que não conheço conta como VIVA (o lado inerte). O teto do mini e o do Hetzner não entram na conta.

TRÊS ESTADOS  tem / não tem / não consegui saber: cada leitura abaixo diz, em comentário, o que o código faz no vazio e no que falhou, e falhou NUNCA vira `node`. Gate que RECUSA (ok false) → local, sem esperar a lista.

Env (teste): MBP_NODE_GATE_CMD e MBP_NODE_SESSIONS_CMD (lista JSON de argv que troca o gc-session-ssh / o `gc session list`; texto não-JSON ou lista vazia = unknown, nunca o padrão),
  MBP_NODE_GATE_TIMEOUT_S (25) e MBP_NODE_SESSIONS_TIMEOUT_S (35): inteiro de 1 a 40; outro valor volta ao padrão (nunca a um prazo maior que o do despachante). GC_CITY: a cidade.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.realpath(__file__))
CITY = os.environ.get("GC_CITY") or os.path.dirname(HERE)
HOST = "mbp"
TEMPLATE = "wa-worker-remote-mbp"
MBP_NAME_RE = re.compile(r"(^|-)remote-mbp-")        # o mesmo pedido de host que o provider lê no nome da sessão (host_of)
DEAD_STATE_RE = re.compile(r"closed|stopped|archived|drained|asleep")   # o mesmo corte do wa-node-dispatch.sh (+ asleep: o modo pilot não conta dormindo)


def timeout_s(name: str, default: int) -> int:
    # vazio (variável ausente ou vazia) → o padrão; ilegível (não é inteiro, fora de 1..40) → o padrão também: um erro de digitação nunca alonga o prazo
    raw = os.environ.get(name, "")
    if raw.isdigit() and raw.isascii() and 1 <= int(raw) <= 40:
        return int(raw)
    return default


def cmd_from_env(name: str, default: list) -> list:
    """argv da leitura. Variável ausente ou vazia → o padrão; presente e ilegível (não é uma lista JSON de textos, ou é vazia) → ValueError, que o chamador lê como `unknown`."""
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        v = json.loads(raw)
    except ValueError as e:
        raise ValueError(f"{name} não é JSON ({e})")
    if not isinstance(v, list) or not v or not all(isinstance(x, str) and x for x in v):
        raise ValueError(f"{name} tem que ser uma lista JSON não vazia de textos")
    return v


class Job:
    """Um comando com prazo, em thread própria e em grupo de processos próprio (o prazo mata o grupo, não deixa o mbp-run.sh órfão). Resultado: ('ran', rc, out, err) ou ('unknown', razão, detalhe)."""

    def __init__(self, label: str, cmd: list, timeout: int):
        self.label, self.cmd, self.timeout = label, cmd, timeout
        self.proc = None
        self.result = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def _run(self):
        # não rodou (script ausente, sem permissão) → unknown; rodou → o que ele disse, inclusive rc ≠ 0 (quem lê decide)
        try:
            self.proc = subprocess.Popen(self.cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        except OSError as e:
            self.result = ("unknown", f"{self.label}_nao_roda", f"{type(e).__name__}: {e}")
            return
        try:
            out, err = self.proc.communicate(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            try:
                self.proc.communicate(timeout=2)
            except Exception:
                pass
            self.result = ("unknown", f"{self.label}_prazo", f"não respondeu em {self.timeout}s")
            return
        self.result = ("ran", self.proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"))

    def kill(self):
        p = self.proc
        if p is not None and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass

    def wait(self):
        self.thread.join(self.timeout + 5)
        if self.result is None:   # a thread nem terminou: prazo estourado por dentro. Não sei.
            self.kill()
            return ("unknown", f"{self.label}_prazo", f"sem resposta em {self.timeout}s")
        return self.result


def one_line(text: str, limit: int = 200) -> str:
    return " ".join(str(text).split())[:limit]


def judge_gate(res):
    """('ok', cap, slot_cap) | ('local', razão) | ('unknown', código, detalhe)."""
    if res[0] == "unknown":
        return res
    _, rc, out, err = res
    # vazio (stdout sem nada) → unknown: o provider SEMPRE imprime o JSON do veredito, até para recusar; falhou/ilegível (host fora da config, config ilegível, texto solto) → unknown também
    try:
        doc = json.loads(out)
    except ValueError:
        doc = None
    if not isinstance(doc, dict):
        return ("unknown", "gate_ilegivel", f"rc={rc}, sem JSON do veredito ({one_line(err or out) or 'saída vazia'})")
    ok = doc.get("ok")
    if rc == 1 and ok is False:
        why = doc.get("reason")
        return ("local", one_line(why) if isinstance(why, str) and why.strip() else "o gate recusou sem dizer o motivo")
    if rc == 0 and ok is True:
        # slot_cap e cap ausentes, nulos, texto, booleano ou < 1 → unknown: "ok" sem teto lido não é "livre" (host sem presence_gate devolve ok com slot_cap nulo)
        cap, slot = doc.get("cap"), doc.get("slot_cap")
        for nm, v in (("cap", cap), ("slot_cap", slot)):
            if not isinstance(v, int) or isinstance(v, bool) or v < 1:
                return ("unknown", "gate_sem_teto", f"o gate liberou mas {nm}={v!r} não é um inteiro >= 1 (host sem regra de presença?)")
        if doc.get("host") != HOST:
            return ("unknown", "gate_outro_host", f"o veredito é do host {doc.get('host')!r}, não de {HOST!r}")
        return ("ok", cap, slot)
    return ("unknown", "gate_incoerente", f"rc={rc} e ok={ok!r} não combinam (0 libera com ok true; 1 recusa com ok false)")


def judge_sessions(res):
    """('ok', vivas) | ('unknown', código, detalhe)."""
    if res[0] == "unknown":
        return res
    _, rc, out, err = res
    if rc != 0:
        return ("unknown", "sessoes_falhou", f"gc session list saiu com {rc} ({one_line(err) or 'sem mensagem'})")
    # vazio ({"sessions": []}) → 0 vivas, vagas cheias; falhou/ilegível (não é JSON, sem a chave sessions, sessions que não é lista, item que não é objeto) → unknown, nunca "0 vivas"
    try:
        doc = json.loads(out)
    except ValueError:
        doc = None
    rows = doc.get("sessions") if isinstance(doc, dict) else None
    if not isinstance(rows, list):
        return ("unknown", "sessoes_ilegiveis", "gc session list não devolveu {\"sessions\": [...]}")
    live = 0
    for s in rows:
        if not isinstance(s, dict):
            return ("unknown", "sessoes_ilegiveis", "um item de sessions não é objeto")
        names = [s.get(k) for k in ("template", "session_name", "name", "alias")]
        if not all(n is None or isinstance(n, str) for n in names):
            return ("unknown", "sessoes_ilegiveis", "template/nome/alias de sessão que não é texto")
        tpl, rest = names[0] or "", names[1:]
        if tpl != TEMPLATE and not any(n and MBP_NAME_RE.search(n) for n in rest):
            continue                                         # não é do MBP
        state = s.get("state") if isinstance(s.get("state"), str) else ""   # estado ausente ou ilegível → "" → não bate no corte → VIVA (o inerte)
        if s.get("closed") is True or DEAD_STATE_RE.search(state):
            continue
        live += 1
    return ("ok", live)


def verdict() -> tuple:
    """(exit code, documento). Gate primeiro: se ele recusa ou não se sabe, a lista de sessões nem é olhada."""
    try:
        gate_cmd = cmd_from_env("MBP_NODE_GATE_CMD", [os.path.join(HERE, "gc-session-ssh"), "gate", HOST])
        sess_cmd = cmd_from_env("MBP_NODE_SESSIONS_CMD", ["gc", "--city", CITY, "session", "list", "--json"])
    except ValueError as e:
        return 2, {"verdict": "unknown", "reason": "config", "detail": str(e), "free": None}
    gate = Job("gate", gate_cmd, timeout_s("MBP_NODE_GATE_TIMEOUT_S", 25))
    sess = Job("sessoes", sess_cmd, timeout_s("MBP_NODE_SESSIONS_TIMEOUT_S", 35))
    gate.start()
    sess.start()
    try:
        g = judge_gate(gate.wait())
        if g[0] == "local":
            return 1, {"verdict": "local", "reason": "gate", "detail": g[1], "free": None}
        if g[0] == "unknown":
            return 2, {"verdict": "unknown", "reason": g[1], "detail": g[2], "free": None}
        _, cap, slot = g
        s = judge_sessions(sess.wait())
        if s[0] == "unknown":
            return 2, {"verdict": "unknown", "reason": s[1], "detail": s[2], "free": None, "host_cap": cap, "slot_cap": slot}
        effective = min(cap, slot)
        free = effective - s[1]
        base = {"host_cap": cap, "slot_cap": slot, "effective": effective, "live": s[1], "free": max(free, 0)}
        if free < 1:
            return 1, dict(base, verdict="local", reason="sem_vaga", detail=f"teto {effective} (cap {cap}, slot_cap {slot}) e {s[1]} sessão(ões) do MBP viva(s)")
        return 0, dict(base, verdict="node", reason="ok", detail=f"Athos fora e MBP saudável; {free} vaga(s) de {effective}")
    finally:
        gate.kill()
        sess.kill()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="mbp-node-capacity.py", add_help=True)
    ap.add_argument("--json", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS)   # a opção vale antes OU depois do comando
    sub.add_parser("verdict", parents=[common])
    args = ap.parse_args(argv)
    try:
        rc, doc = verdict()
    except Exception as e:   # defeito nosso: não sei (2), nunca um veredito inventado
        rc, doc = 2, {"verdict": "unknown", "reason": "interno", "detail": f"{type(e).__name__}: {e}", "free": None}
    if args.json:
        print(json.dumps(doc, ensure_ascii=False, sort_keys=True))
    else:
        print(f"{doc['verdict']} {doc['reason']}: {doc.get('detail', '')}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
