#!/usr/bin/env python3
"""Selftest do crew-idle-wake (ga-esorlre.14). Roda sem tmux/bd reais: o runner é falso.

## Contents
- Casos da noite 25-26/11 · Tela · Falhas · Teto de tentativas

Uso: python3 crew-idle-wake.selftest.py   (exit 0 = passou)
"""
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

AQUI = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp())
os.environ.update(CREW_IDLE_WAKE_STATE=str(TMP / "st"), CREW_IDLE_WAKE_LOG=str(TMP / "log"),
                  CREW_IDLE_WAKE_STORES=str(TMP), CREW_IDLE_WAKE_IDLE_SEC="600", GC_CITY_PATH=str(TMP))
spec = importlib.util.spec_from_file_location("ciw", AQUI / "crew-idle-wake.py")
ciw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ciw)
ciw.time.sleep = lambda *_: None

OCIOSA = "⏺ Combinado, deixei essa pergunta de lado.\n\n───────\n❯ \n───────\n  [Opus 5.5] ctx: 9%\n  ⏵⏵ bypass permissions on\n"
OCUPADA = "✳ Twisting… (5m)\n───────\n❯ \n───────\n  ⏵⏵ bypass permissions on · esc to interrupt\n"
PERGUNTA = "☐ Reboot hoje\n❯ 1. Reboot + eu acordo\n  2. Segurar\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"
DIGITANDO = "⏺ ok\n───────\n❯ vamos executar as be\n───────\n"
ok = 0


def check(cond, nome):
    global ok
    assert cond, nome
    print("  ✓", nome)
    ok += 1


class Runner:
    def __init__(self, sess, beads, telas, falha_tmux=False, falha_bd=False):
        self.sess, self.beads, self.telas = sess, beads, telas
        self.falha_tmux, self.falha_bd, self.enviados, self.mails = falha_tmux, falha_bd, [], []

    def __call__(self, cmd, timeout=30):
        if cmd[:2] == ["tmux", "ls"]:
            return (None, "", "") if self.falha_tmux else (0, "\n".join(self.sess), "")
        if cmd[0] == "bd":
            return (1, "", "dolt down") if self.falha_bd else (0, json.dumps(self.beads), "")
        if cmd[:2] == ["tmux", "capture-pane"]:
            return 0, self.telas[cmd[cmd.index("-t") + 1]], ""
        if cmd[:2] == ["tmux", "send-keys"]:
            self.enviados.append((cmd[3], cmd[-1]))
            return 0, "", ""
        if cmd[:3] == ["gc", "mail", "send"]:
            self.mails.append(cmd[cmd.index("-s") + 1])
            return 0, "", ""
        raise AssertionError(cmd)


def limpa():
    for f in (TMP / "st").glob("*.json"):
        f.unlink()


PETER = {"id": "wa-axkxf5.34", "assignee": "peter-wa", "labels": ["pilot:no-auto-dispatch", "story:approved"]}
ORACLE = {"id": "wa-ru0lnf", "assignee": "oracle-wa", "labels": ["story:in-flight"]}

# 1. a noite do Peter: pilot:no-auto-dispatch com dono é trabalho, e a ordem entra no pane depois de 10 min parada
limpa()
r = Runner(["peter-wa-gawispzy8voe"], [PETER], {"peter-wa-gawispzy8voe": OCIOSA})
ciw.passada(run=r, agora=1000)
check(r.enviados == [], "1a. 1ª passada só marca o início da ociosidade")
ciw.passada(run=r, agora=1000 + 599)
check(r.enviados == [], "1b. 9 min 59 s parada: ainda não")
ciw.passada(run=r, agora=1000 + 600)
check(len(r.enviados) == 2 and "wa-axkxf5.34" in r.enviados[0][1] and r.enviados[1][1] == "Enter",
      "1c. 10 min parada com pilot:no-auto-dispatch: texto e Enter em chamadas separadas")

# 2. sessão ocupada, pergunta aberta, alguém digitando: nunca injeta
for nome, t in (("ocupada", OCUPADA), ("pergunta", PERGUNTA), ("digitando", DIGITANDO)):
    limpa()
    r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": t})
    for k in range(4):
        ciw.passada(run=r, agora=1000 + k * 700)
    check(r.enviados == [], f"2. tela {nome}: nenhuma ordem")

# 3. bead esperando outra pessoa / gate: não é pendente
for lab in ("next-action:mayor", "waiting-on:athos", "gate:queued", "blocked-reason:decision"):
    limpa()
    r = Runner(["oracle-wa-gawispgux5v0"], [dict(ORACLE, labels=[lab])], {"oracle-wa-gawispgux5v0": OCIOSA})
    for k in range(3):
        ciw.passada(run=r, agora=1000 + k * 700)
    check(r.enviados == [], f"3. {lab}: não acorda")

# 4. tela que mudou recomeça o relógio
limpa()
telas = {"oracle-wa-gawispgux5v0": OCIOSA}
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], telas)
ciw.passada(run=r, agora=1000)
telas["oracle-wa-gawispgux5v0"] = OCIOSA.replace("Combinado", "Feito")
ciw.passada(run=r, agora=1700)
check(r.enviados == [], "4. tela mudou: o relógio recomeça")

# 5. teto: 3 ordens sem a BEAD andar → 1 mail ao Mayor, e para — mesmo com a tela mudando a cada ordem (a resposta curta do agente)
limpa()
telas = {"oracle-wa-gawispgux5v0": OCIOSA}
r = Runner(["oracle-wa-gawispgux5v0"], [dict(ORACLE, updated_at="2026-11-26T03:00:00Z")], telas)
for k in range(30):
    n_antes = len(r.enviados)
    ciw.passada(run=r, agora=1000 + k * 601)
    if len(r.enviados) > n_antes:      # o agente «responde» e para de novo: a tela muda
        telas["oracle-wa-gawispgux5v0"] = OCIOSA.replace("Combinado", f"Ok {k}")
ordens = [e for e in r.enviados if e[1] != "Enter"]
check(len(ordens) == 3 and len(r.mails) == 1, "5a. 3 ordens sem a bead andar → 1 mail ao Mayor, sem 4ª ordem")
r.beads = [dict(ORACLE, updated_at="2026-11-26T09:00:00Z")]      # a bead andou: novo episódio
for k in range(30, 32):      # 30 marca o início da ociosidade, 31 (10 min depois) acorda
    ciw.passada(run=r, agora=1000 + k * 601)
ordens = [e for e in r.enviados if e[1] != "Enter"]
check(len(ordens) == 4, "5b. a bead andou e parou de novo: o vigia volta a acordar")

# 6. falhas: tmux/bd sem resposta → nenhuma ordem; 5 seguidas → mail «cego»
limpa()
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA}, falha_bd=True)
for k in range(6):
    ciw.passada(run=r, agora=1000 + k * 700)
check(r.enviados == [] and r.mails == ["crew-idle-wake cego"], "6a. bd fora: nada injetado, 1 aviso de vigia cego")
limpa()
r = Runner([], [ORACLE], {}, falha_tmux=True)
check(ciw.sessoes_tmux(r) is None, "6b. tmux sem resposta = não sei (None), nunca «nenhuma sessão»")

# 7. pool fica de fora; Mayor casa por «gastown.mayor» → «gastown__mayor»
check(ciw.e_pool("wa-worker-adhoc-0cad1bdf00") and ciw.e_pool("dog-ga2695nnf"), "7a. pools fora do vigia")
check(ciw.dono_da_sessao("gastown__mayor", "gastown.mayor"), "7b. Mayor casa pelo nome do tmux")
check(not ciw.dono_da_sessao("oracle-wa-gawispgux5v0", "oracle"), "7c. prefixo solto não casa")

print(f"\n{ok} passaram")
