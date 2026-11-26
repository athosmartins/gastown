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
    def __init__(self, sess, beads, telas, falha_tmux=False, falha_bd=False, falha_mail=False, falha_keys=False):
        self.sess, self.beads, self.telas = sess, beads, telas
        self.falha_tmux, self.falha_bd, self.enviados, self.mails = falha_tmux, falha_bd, [], []
        self.falha_mail, self.falha_keys, self.mails_tentados = falha_mail, falha_keys, 0

    def __call__(self, cmd, timeout=30):
        if cmd[0] == "tmux":
            # gate ga-lw03yn6: toda chamada tmux vai pro servidor da cidade (-L gascity), nunca pro padrão
            assert cmd[1:3] == ["-L", "gascity"], f"tmux sem o socket da cidade: {cmd}"
            sub = cmd[3]
            if sub == "ls":
                return (None, "", "") if self.falha_tmux else (0, "\n".join(self.sess), "")
            if sub == "capture-pane":
                return 0, self.telas[cmd[cmd.index("-t") + 1]], ""
            if sub == "send-keys":
                if self.falha_keys:
                    return 1, "", "can't find pane"
                self.enviados.append((cmd[cmd.index("-t") + 1], cmd[-1]))
                return 0, "", ""
        if cmd[0] == "bd":
            return (1, "", "dolt down") if self.falha_bd else (0, json.dumps(self.beads), "")
        if cmd[:3] == ["gc", "mail", "send"]:
            self.mails_tentados += 1
            if self.falha_mail:
                return 1, "", "dolt down"
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

# 6c. bd responde rc 0 com JSON corrompido → ilegível (None), nenhuma ordem
class RunnerJsonRuim(Runner):
    def __call__(self, cmd, timeout=30):
        if cmd[0] == "bd":
            return 0, "{corrompido", ""
        return super().__call__(cmd, timeout)
limpa()
r = RunnerJsonRuim(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA})
check(ciw.beads_em_andamento(str(TMP), r) is None, "6c. JSON corrompido do bd = não sei (None), nunca «nenhuma bead»")
for k in range(4):
    ciw.passada(run=r, agora=1000 + k * 700)
check(r.enviados == [], "6d. com o bd ilegível nenhuma ordem sai")

# 6e. arquivo de estado corrompido/ilegível → recomeça o relógio (não injeta na hora)
limpa()
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA})
ciw.passada(run=r, agora=1000)
(TMP / "st" / "oracle-wa-gawispgux5v0.json").write_text("{lixo")
ciw.passada(run=r, agora=1000 + 700)
check(r.enviados == [], "6e. estado corrompido: o relógio recomeça, nenhuma ordem por palpite")
ciw.passada(run=r, agora=1000 + 1400)
check(len(r.enviados) == 2, "6f. e 10 min depois a ordem sai normalmente")

# 8. gate ga-lw03yn6 — tela que o vigia não reconhece nunca recebe ordem; «Try "..."» é caixa vazia
for nome, t in (("vazia", ""), ("shell", "athos@mini ~ % \n"), ("transcript", "  ⎿ Read 1 file\n  ⎿ Ran 2 commands\n")):
    check(ciw.estado_da_tela(t) == "desconhecida", f"8a. tela {nome}: desconhecida")
check(ciw.estado_da_tela('───────\n❯ Try "fix lint errors"\n───────\n') == "ociosa", "8b. «Try ...» de conversa sem turno = caixa vazia")
check(ciw.estado_da_tela("───────\n❯ 1. Sim\n  2. Não\n") == "pergunta", "8c. menu numerado = pergunta")
check(ciw.estado_da_tela(OCIOSA.replace("bypass permissions on", "bypass permissions on · 2 shells")) == "ocupada",
      "8d. trabalho de fundo no rodapé = ocupada")
limpa()
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": "athos@mini ~ % "})
for k in range(4):
    ciw.passada(run=r, agora=1000 + k * 700)
check(r.enviados == [], "8e. pane de shell parado: nenhuma ordem")

# 9. gate ga-lw03yn6 — dry-run não grava estado
limpa()
ciw._DRY = True
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA})
for k in range(5):
    ciw.passada(dry=True, run=r, agora=1000 + k * 700)
ciw._DRY = False
check(not list((TMP / "st").glob("*.json")) and r.enviados == [] and r.mails == [], "9. dry-run: nenhum estado, nenhuma tecla, nenhum mail")

# 10. gate ga-lw03yn6 — mail que falhou não marca avisado (tenta de novo); send-keys que falhou não conta
limpa()
r = Runner([], [ORACLE], {}, falha_bd=True, falha_mail=True)
r.sess = ["oracle-wa-gawispgux5v0"]
for k in range(7):
    ciw.passada(run=r, agora=1000 + k * 700)
check(r.mails_tentados >= 2 and r.mails == [], "10a. mail «cego» que falhou é tentado de novo na passada seguinte")
limpa()
r = Runner(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA}, falha_keys=True)
for k in range(8):
    ciw.passada(run=r, agora=1000 + k * 700)
check(r.mails == [] and not ciw.ler_estado("oracle-wa-gawispgux5v0").get("tentativas"),
      "10b. send-keys que falha não conta tentativa nem dispara o mail de «não reage»")

# 11. gate ga-c2ci9f8 — um store que cai no meio do episódio não zera tentativas nem o aviso
limpa()
st_a, st_b = TMP / "storeA", TMP / "storeB"
st_a.mkdir(exist_ok=True); st_b.mkdir(exist_ok=True)
ciw.STORES = [str(st_a), str(st_b)]


class Runner2(Runner):
    cai = False

    def __call__(self, cmd, timeout=30):
        if cmd[0] == "bd":
            if cmd[2] == str(st_b):
                return (1, "", "timeout") if self.cai else (0, json.dumps(self.beads), "")
            return 0, "[]", ""
        return super().__call__(cmd, timeout)


r = Runner2(["oracle-wa-gawispgux5v0"], [ORACLE], {"oracle-wa-gawispgux5v0": OCIOSA})
for k in range(5):
    ciw.passada(run=r, agora=1000 + k * 601)
antes = ciw.ler_estado("oracle-wa-gawispgux5v0")
r.cai = True
ciw.passada(run=r, agora=1000 + 5 * 601)
check(ciw.ler_estado("oracle-wa-gawispgux5v0") == antes and antes.get("tentativas"), "11. store que cai não zera o episódio")
ciw.STORES = [str(TMP)]

# 7. pool fica de fora; Mayor casa por «gastown.mayor» → «gastown__mayor»
check(ciw.e_pool("wa-worker-adhoc-0cad1bdf00") and ciw.e_pool("dog-ga2695nnf"), "7a. pools fora do vigia")
check(ciw.dono_da_sessao("gastown__mayor", "gastown.mayor"), "7b. Mayor casa pelo nome do tmux")
check(not ciw.dono_da_sessao("oracle-wa-gawispgux5v0", "oracle"), "7c. prefixo solto não casa")

print(f"\n{ok} passaram")
