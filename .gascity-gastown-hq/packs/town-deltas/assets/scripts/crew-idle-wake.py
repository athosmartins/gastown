#!/usr/bin/env python3
"""crew-idle-wake — crew PARADA no prompt com trabalho em andamento recebe a ordem de retomar COMO INPUT (ga-esorlre.14).

## Contents
- Por que existe · O que conta como «parada» · O que conta como «trabalho pendente» · O que faz · Falhas · Uso

Por que existe (ga-esorlre.12, noite 25-26/11): depois do reboot das 23:40 a peter-wa e a oracle-wa ficaram paradas no
prompt até o Athos digitar de manhã. O vigia antigo (agent-stuck-escalation) não acordou nenhuma das duas:
  - peter-wa (wa-axkxf5.34): 359 passadas suprimidas por «PARK canônico» — a marca era `pilot:no-auto-dispatch`, que
    com dono quer dizer «não despache, o dono está fazendo», não «parada esperando decisão»;
  - oracle-wa: o .jsonl não teve NENHUMA escrita de 02:55Z a 08:53Z, mas o vigia leu «transcript avançando»,
    «AskUserQuestion pendente» e «gc session list falhou» — os três suprimem;
  - e o aviso que ele manda passa por `gc session nudge`, que numa sessão ociosa vira reminder diferido: só aparece
    quando um humano digita.
Este vigia não lê transcript nem `gc session list` (que estourava 30 s sob carga): decide pela TELA do tmux e pelas beads.

O que conta como «parada» (todas, na mesma passada e na anterior):
  - a tela do pane não tem «esc to interrupt» (o Claude Code só mostra isso com turno rodando);
  - não há pergunta aberta na tela (AskUserQuestion: «Enter to select»; permissão: «Do you want to proceed?») —
    aí a vez é de um humano, e quem cuida do prompt de permissão é o agent-stuck-escalation;
  - a caixa de entrada está vazia (ninguém digitando);
  - a tela é IGUAL à da passada anterior há IDLE_MIN_SEC (padrão 600 s).

O que conta como «trabalho pendente»: bead `in_progress` atribuída à sessão (assignee = alias, ou o nome tmux
`<alias>-ga…`). NÃO conta: bead que espera outra pessoa ou o gate (`next-action:*`, `waiting-on:*`, `blocked*`,
`gate:queued|reviewing|merging|passed`). `pilot:no-auto-dispatch` CONTA como pendente (é o caso do Peter).

O que faz: escreve a ordem no pane (`tmux send-keys -l` + Enter em outra chamada) — vira um turno de verdade. Conta as
tentativas; 3 seguidas sem a bead andar (updated_at) → mail ao Mayor (uma vez por episódio) e para de insistir até ela
andar. A tela não zera as tentativas: a própria ordem injetada muda a tela.

Falhas (nunca injeta sob dúvida): `tmux` ou `bd` que não respondem → nenhuma injeção na passada, log «não sei»;
5 passadas seguidas sem conseguir ler → mail ao Mayor (o vigia está cego). Store de beads ilegível (com outro legível) →
as sessões com bead nele não recebem ordem nesta passada e o estado do episódio delas (tentativas, avisado) fica como estava.

Uso: crew-idle-wake.py [--dry-run]   (launchd a cada 120 s; kill switch: .gc/state/crew-idle-wake.disabled)
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

CITY = Path(os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq"))
STATE_DIR = Path(os.environ.get("CREW_IDLE_WAKE_STATE", CITY / ".gc/state/crew-idle-wake"))
LOG = Path(os.environ.get("CREW_IDLE_WAKE_LOG", CITY / ".gc/logs/crew-idle-wake.log"))
KILL = CITY / ".gc/state/crew-idle-wake.disabled"
STORES = os.environ.get("CREW_IDLE_WAKE_STORES",
                        f"{CITY} /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers").split()
IDLE_MIN_SEC = int(os.environ.get("CREW_IDLE_WAKE_IDLE_SEC", "600"))
MAX_KICKS = int(os.environ.get("CREW_IDLE_WAKE_MAX_KICKS", "3"))
BLIND_ALARM_PASSES = 5
# gate ga-d0n3664: lista POSITIVA — o vigia só digita no pane do Mayor e das crews nomeadas (agente da cidade com provider
# claude-rc*, o Remote Control que só Mayor e crews têm). Pool, dog, reviewer ou sessão de nome que ninguém cadastrou: fora.
AGENTS_DIR = Path(os.environ.get("CREW_IDLE_WAKE_AGENTS", CITY / "agents"))
NAO_PENDENTE_PREFIXOS = ("next-action:", "waiting-on:", "blocked")
NAO_PENDENTE_EXATOS = {"gate:queued", "gate:reviewing", "gate:merging", "gate:passed"}
# toda sessão do gc (Mayor e crews) vive no servidor tmux da cidade, não no padrão (gate ga-lw03yn6): sob o launchd não há $TMUX
TMUX = [os.environ.get("CREW_IDLE_WAKE_TMUX") or "tmux", "-L", os.environ.get("CREW_IDLE_WAKE_TMUX_SOCKET") or "gascity"]
# leitura da tela = a MESMA da camada 1 (boot-first-turn.py, ga-esorlre.13), que veio do nightly-session-compact.py
_DUR = r"([0-9]+h[ \t]+)?([0-9]+m[ \t]+)?[0-9]+s"
_GLYPH = r"(✻|✽|✳|✶|✢|✺|✹|·|\*)"
DIALOG_RE = re.compile(r"Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel")
BUSY_RE = re.compile(r"(…|\.\.\.)[^(]*\(" + _DUR + "|esc to interrupt")
SPIN_RE = re.compile(r"^\s*" + _GLYPH + r"\s+\S+(…|\.\.\.)", re.M)
FOOT_RE = re.compile(r"\b\d+ (?:shells?|bash(?:es)?|tasks?|monitors?)\b")
MENU_RE = re.compile(r"^\s*❯\s*\d+\.\s")
PLACEHOLDER_RE = re.compile(r'^Try ".*"$')   # a sugestão de conversa sem turno: caixa VAZIA
_DRY = False      # --dry-run: nada é gravado no estado (gate ga-lw03yn6: o ensaio consumia o alarme real)


def log(msg: str) -> None:
    linha = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] [crew-idle-wake] {msg}"
    print(linha)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as fh:
            fh.write(linha + "\n")
    except OSError:
        pass


def rodar(cmd, timeout=30):
    """(rc, stdout, stderr). Timeout/binário ausente → (None, "", "") = «não respondeu», nunca «vazio»."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, OSError):
        return None, "", ""


# ───────────────────────────── leituras ─────────────────────────────

def sessoes_tmux(run=rodar):
    """Nomes das sessões tmux. vazio → [] (nenhuma sessão); falhou/ilegível → None (não sei)."""
    rc, out, err = run([*TMUX, "ls", "-F", "#{session_name}"], timeout=15)
    if rc == 0:
        return [l.strip() for l in out.splitlines() if l.strip()]
    return [] if rc is not None and ("no server running" in err or "no sessions" in err) else None


def beads_em_andamento(store, run=rodar):
    """Beads in_progress do store. vazio → []; falhou/ilegível → None (sessões com bead neste store ficam sem ordem nesta passada)."""
    rc, out, _ = run(["bd", "-C", store, "list", "--status", "in_progress", "--limit", "0", "--json"], timeout=60)
    if rc != 0:
        return None
    if not (out or "").strip():
        return None          # gate ga-vww9tud: o bd imprime «[]» quando não há bead; stdout VAZIO com rc 0 é «não sei», não «nenhuma»
    try:
        dados = json.loads(out)   # third-state-waiver: JSON corrompido coberto no caso 6c/6d e stdout vazio no 6g e store ausente no 6h de crew-idle-wake.selftest.py (o check não lê selftest .py)
    except ValueError:
        return None
    return dados if isinstance(dados, list) else None


def tela(sess, run=rodar):
    """As últimas 40 linhas do pane. vazio → "" (pane sem texto); falhou → None."""
    rc, out, _ = run([*TMUX, "capture-pane", "-p", "-t", sess, "-S", "-40"], timeout=15)
    return out if rc == 0 else None


# ───────────────────────────── decisões (puras) ─────────────────────────────

MAYORS = ("gastown__mayor", "gastown.mayor", "mayor")   # os 3 grafismos do Mayor (mesma classe do boot-first-turn.py, camada 1)


def dono_da_sessao(sess: str, assignee: str) -> bool:
    """Mesma equivalência da camada 1 (boot-first-turn.owns), gate ga-r62eowk: `oracle-wa`, `oracle-wa/` e `oracle-wa-gawispOUTRA`
    (outra instância da crew) são donos de `oracle-wa-gawispgux5v0`; `mayor`, `mayor/`, `gastown.mayor` e `gastown__mayor` são
    donos da sessão do Mayor."""
    a = (assignee or "").strip().rstrip("/") if isinstance(assignee, str) else ""
    if not a:
        return False
    alias = sess if sess in MAYORS else re.sub(r"-gawisp[a-z0-9]+$", "", sess)
    nomes = {sess, alias} | (set(MAYORS) if alias in MAYORS else set())
    return a in nomes or any(re.fullmatch(re.escape(n) + r"-gawisp[a-z0-9]+", a) for n in nomes)


def crews_nomeadas():
    """Nomes dos agentes com provider claude-rc* em AGENTS_DIR. Diretório ilegível → None («não sei quem é crew»: ninguém
    recebe ordem); agent.toml ilegível → aquele agente fica fora (desconhecido não age)."""
    try:
        dirs = list(AGENTS_DIR.iterdir())   # third-state-waiver: diretório ausente coberto no caso 7i de crew-idle-wake.selftest.py (o check não lê selftest .py)
    except OSError:
        return None
    crews = set()
    for d in dirs:
        try:
            txt = (d / "agent.toml").read_text()   # third-state-waiver: agent.toml ausente (sem-toml) coberto no caso 7a de crew-idle-wake.selftest.py
        except OSError:
            continue
        if re.search(r'^provider\s*=\s*"claude-rc', txt, re.M):
            crews.add(d.name)
    return crews


def e_vigiada(nome: str, crews) -> bool:
    return nome in MAYORS or re.sub(r"-gawisp[a-z0-9]+$", "", nome) in (crews or ())


def pendente(bead: dict) -> bool:
    labels = set(bead.get("labels") or [])
    if labels & NAO_PENDENTE_EXATOS:
        return False
    return not any(l.startswith(NAO_PENDENTE_PREFIXOS) for l in labels)


def estado_da_tela(texto: str) -> str:
    """'ociosa' SÓ com o prompt do Claude à vista, nada rodando, nenhum diálogo, caixa vazia (a sugestão «Try "..."» conta
    como vazia) e nenhum trabalho de fundo no rodapé. Senão: 'ocupada' | 'pergunta' | 'digitando' | 'desconhecida' (tela que
    o vigia não soube ler — pane vazio, shell, transcript: nunca recebe ordem). Mesmas regras de boot-first-turn.read_pane."""
    linhas = [x.rstrip() for x in texto.splitlines() if x.strip()]
    prompt = next((x for x in reversed(linhas) if x.lstrip().startswith("❯")), None)
    if DIALOG_RE.search("\n".join(linhas[-12:])):
        return "pergunta"
    if BUSY_RE.search(texto):
        return "ocupada"
    if SPIN_RE.search(texto) or prompt is None:
        return "desconhecida"
    if MENU_RE.match(prompt):
        return "pergunta"
    rascunho = prompt.lstrip()[1:].strip()
    if rascunho and not PLACEHOLDER_RE.match(rascunho):
        return "digitando"
    if any("·" in x and FOOT_RE.search(x) for x in linhas[-3:]):
        return "ocupada"
    return "ociosa"


def assinatura(texto: str) -> str:
    # a linha de status muda sozinha (contexto, relógio, workers): compara só o corpo acima das réguas da caixa
    corpo = texto.split("\n───")[0] if "\n───" in texto else texto
    return hashlib.sha256(corpo.encode()).hexdigest()[:16]


def mensagem(ids, minutos: int) -> str:
    lista = ", ".join(ids[:5])
    return (f"[vigia ga-esorlre.14] Você está parado há {minutos} min com trabalho em andamento: {lista}. "
            f"Retome agora (bd show + último comentário/handoff da bead) e siga até terminar. "
            f"Se está esperando alguém, registre na bead (next-action:mayor + comentário, ou AskUserQuestion ao Athos) "
            f"em vez de ficar parado.")


# ───────────────────────────── estado ─────────────────────────────

def ler_estado(nome: str) -> dict:
    try:
        return json.loads((STATE_DIR / f"{nome}.json").read_text())   # third-state-waiver: estado ilegível/corrompido coberto no caso 6e/6f de crew-idle-wake.selftest.py
    except (OSError, ValueError):
        return {}


def gravar_estado(nome: str, st: dict) -> None:
    if _DRY:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / f"{nome}.json").write_text(json.dumps(st))


def mail_mayor(assunto: str, corpo: str, dry: bool, run=rodar) -> bool:
    """True só se o mail SAIU. Falhou → False e quem chama NÃO marca como avisado (tenta de novo na próxima passada)."""
    if dry:
        log(f"DRY-RUN mail ao Mayor: {assunto}")
        return False
    rc, _, _ = run(["gc", "mail", "send", "mayor/", "-s", assunto, "-m", corpo], timeout=60)
    if rc != 0:
        log(f"mail ao Mayor FALHOU ({assunto}) — tento de novo na próxima passada")
        return False
    return True


def injetar(sess: str, texto: str, dry: bool, run=rodar) -> bool:
    if dry:
        log(f"DRY-RUN injetaria em {sess}: {texto[:90]}…")
        return True
    rc1, _, _ = run([*TMUX, "send-keys", "-t", sess, "-l", texto], timeout=15)
    if rc1 != 0:
        return False      # o texto não entrou: nem tenta o Enter
    time.sleep(1)
    rc2, _, _ = run([*TMUX, "send-keys", "-t", sess, "Enter"], timeout=15)
    return rc2 == 0


# ───────────────────────────── passada ─────────────────────────────

def passada(dry: bool = False, run=rodar, agora=None) -> int:
    agora = agora or time.time()
    cego = ler_estado("_cego")
    sess_list = sessoes_tmux(run)
    # gate ga-vww9tud: store configurado que sumiu não é descartado em silêncio — `bd -C` num caminho ausente sai rc≠0 → None → «ilegível»
    lidos = {s: beads_em_andamento(s, run) for s in STORES}
    crews = crews_nomeadas()
    if crews is None:
        log(f"NÃO SEI quais sessões são crews: {AGENTS_DIR} ilegível — nenhuma ordem nesta passada")
    if sess_list is None or crews is None or all(v is None for v in lidos.values()):
        n = cego.get("passadas", 0) + 1
        gravar_estado("_cego", {"passadas": n, "avisado": cego.get("avisado", False)})
        log(f"NÃO SEI: tmux={'falhou' if sess_list is None else 'ok'}, stores ilegíveis — nenhuma injeção ({n} seguida(s))")
        if n >= BLIND_ALARM_PASSES and not cego.get("avisado"):
            if mail_mayor("crew-idle-wake cego", f"{n} passadas seguidas sem ler tmux/beads: crew parada não seria acordada.", dry, run):
                gravar_estado("_cego", {"passadas": n, "avisado": True})
        return 0
    gravar_estado("_cego", {"passadas": 0, "avisado": False})
    beads = [b for v in lidos.values() if v for b in v]
    ilegiveis = [st for st, v in lidos.items() if v is None]
    for store, v in lidos.items():
        if v is None:
            log(f"store ilegível nesta passada: {store} — sessões com bead nele ficam sem ordem nesta passada")
    # gate ga-r62eowk: bead em andamento cujo dono não casa sessão viva nenhuma é «não sei de quem é» — contada e nomeada no log,
    # nunca misturada em silêncio às casadas
    orfas = [b.get("id") for b in beads if (b.get("assignee") or "").strip() and not any(dono_da_sessao(x, b.get("assignee")) for x in sess_list)]
    if orfas:
        log(f"{len(orfas)} bead(s) em andamento sem sessão viva do dono: {', '.join(map(str, orfas[:8]))}{' …' if len(orfas) > 8 else ''}")
    injetadas = 0
    for sess in sess_list:
        if not e_vigiada(sess, crews):
            continue
        minhas = [b for b in beads if dono_da_sessao(sess, b.get("assignee", ""))]
        trabalho = [b["id"] for b in minhas if pendente(b)]
        st = ler_estado(sess)
        if not trabalho:
            # gate ga-c2ci9f8: com algum store ilegível, «sem trabalho» pode ser só a bead que não veio — o estado do episódio
            # (tentativas, avisado) fica como está; só uma leitura completa de todos os stores pode zerá-lo
            if st and not ilegiveis:
                gravar_estado(sess, {})
            continue
        texto = tela(sess, run)
        if texto is None:
            log(f"{sess}: não li a tela — sem veredito")
            continue
        estado = estado_da_tela(texto)
        if estado == "desconhecida":
            log(f"{sess}: não reconheci o prompt do Claude na tela — sem ordem nesta passada")
        sig = assinatura(texto)
        # progresso de verdade = a bead andou (updated_at; no bd 1.1.0 só bd update o move — bd comment e bd label NÃO, então
        # crew que só comenta conta como parada e o teto de 3 ordens limita o custo). A tela NÃO serve pra
        # isso: a própria ordem injetada muda a tela, e o teto de tentativas nunca dispararia.
        prog = max(str(b.get("updated_at") or "") for b in minhas if b["id"] in trabalho)
        # gate ga-z3s8i5y: com algum store ilegível o `prog` só vê parte das beads — «mudou» pode ser só a bead que não veio.
        # «A bead andou» (e o episódio recomeçar) só com TODOS os stores lidos E um prog gravado completo; senão vale o gravado.
        # gate ga-anzip7u: episódio que nasce com store ilegível grava o prog como «parcial»; quando todos os stores leem,
        # adota o prog completo SEM zerar tentativas/avisado (subir ali é a bead que não veio, não a bead que andou).
        if "prog" not in st:
            st = {"prog": prog, "tentativas": 0, "avisado": False, "parcial": bool(ilegiveis)}
        elif st.get("parcial"):
            if not ilegiveis:
                st.update({"prog": prog, "parcial": False})
                gravar_estado(sess, st)
        elif st.get("prog") != prog and not ilegiveis:
            st = {"prog": prog, "tentativas": 0, "avisado": False, "parcial": False}
        if estado != "ociosa" or st.get("sig") != sig:
            # tela mudou (ou não está ociosa): só o relógio da ociosidade recomeça; as tentativas seguem até a bead andar
            st.update({"sig": sig, "desde": agora} if estado == "ociosa" else {"sig": None, "desde": agora})
            gravar_estado(sess, st)
            continue
        parado = agora - st.get("desde", agora)
        if parado < IDLE_MIN_SEC:
            continue
        if st.get("tentativas", 0) >= MAX_KICKS:
            if not st.get("avisado") and mail_mayor(
                    f"crew {sess} não reage ao vigia (ga-esorlre.14)",
                    f"{sess} parada há {int(parado // 60)} min com {', '.join(trabalho)}; {MAX_KICKS} ordens ENTREGUES no pane "
                    f"sem a bead andar. Confira com gc session peek {sess}.", dry, run):
                st["avisado"] = True
                gravar_estado(sess, st)
            continue
        msg = mensagem(trabalho, int(parado // 60))
        if not injetar(sess, msg, dry, run):
            # o vigia não conseguiu digitar: NÃO conta como ordem entregue (o mail do teto afirma «ordens entregues») e o
            # relógio não recomeça — tenta de novo na próxima passada
            log(f"{sess}: parada {int(parado // 60)} min com {', '.join(trabalho)} → send-keys FALHOU, não contado")
            continue
        st["tentativas"] = st.get("tentativas", 0) + 1
        st["desde"] = agora          # a próxima tentativa só depois de mais IDLE_MIN_SEC parada
        gravar_estado(sess, st)
        log(f"{sess}: parada {int(parado // 60)} min com {', '.join(trabalho)} → ordem no pane "
            f"(tentativa {st['tentativas']}/{MAX_KICKS}{', dry-run' if dry else ''})")
        injetadas += 1
    log(f"passada ok: {len(sess_list)} sessão(ões), {len(beads)} bead(s) em andamento, {injetadas} ordem(ns)")
    return injetadas


def main() -> int:
    if KILL.exists():
        log("kill switch ligado — nada a fazer")
        return 0
    import fcntl
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    trava = open(STATE_DIR / "_instancia.lock", "w")
    try:      # instância única: com a máquina carregada uma passada pode passar de 120 s, e o launchd empilharia outra
        fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("outra passada ainda rodando — esta sai sem fazer nada")
        return 0
    global _DRY
    _DRY = "--dry-run" in sys.argv
    passada(dry=_DRY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
