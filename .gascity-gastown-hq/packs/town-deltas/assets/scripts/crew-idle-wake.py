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
as sessões com bead nele não recebem ordem nesta passada e o relógio delas recomeça (inerte: atrasa, nunca injeta por palpite).

Uso: crew-idle-wake.py [--dry-run]   (launchd a cada 120 s; kill switch: .gc/state/crew-idle-wake.disabled)
"""
from __future__ import annotations

import hashlib
import json
import os
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
# pools têm ciclo de vida próprio (sobem pra uma bead e saem); este vigia é das crews nomeadas e do Mayor
POOL_PREFIXES = ("wa-worker", "ps-worker", "dog", "gastown.dog", "gate-reviewer", "kimi-worker", "refine")
NAO_PENDENTE_PREFIXOS = ("next-action:", "waiting-on:", "blocked")
NAO_PENDENTE_EXATOS = {"gate:queued", "gate:reviewing", "gate:merging", "gate:passed"}
BUSY = "esc to interrupt"
PERGUNTA_ABERTA = ("Enter to select", "Do you want to proceed?")


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
    rc, out, err = run(["tmux", "ls", "-F", "#{session_name}"], timeout=15)
    if rc == 0:
        return [l.strip() for l in out.splitlines() if l.strip()]
    return [] if rc is not None and ("no server running" in err or "no sessions" in err) else None


def beads_em_andamento(store, run=rodar):
    """Beads in_progress do store. vazio → []; falhou/ilegível → None (sessões com bead neste store ficam sem ordem nesta passada)."""
    rc, out, _ = run(["bd", "-C", store, "list", "--status", "in_progress", "--limit", "0", "--json"], timeout=60)
    if rc != 0:
        return None
    try:
        dados = json.loads(out or "[]")
    except ValueError:
        return None
    return dados if isinstance(dados, list) else None


def tela(sess, run=rodar):
    """As últimas 40 linhas do pane. vazio → "" (pane sem texto); falhou → None."""
    rc, out, _ = run(["tmux", "capture-pane", "-p", "-t", sess, "-S", "-40"], timeout=15)
    return out if rc == 0 else None


# ───────────────────────────── decisões (puras) ─────────────────────────────

def dono_da_sessao(sess: str, assignee: str) -> bool:
    """`oracle-wa` é dono de `oracle-wa-gawispgux5v0`; `gastown.mayor` é dono de `gastown__mayor` (o tmux troca «.» por «__»)."""
    a = (assignee or "").strip()
    if not a:
        return False
    return any(sess == x or sess.startswith(x + "-ga") for x in {a, a.replace(".", "__")})


def e_pool(nome: str) -> bool:
    return nome.startswith(POOL_PREFIXES)


def pendente(bead: dict) -> bool:
    labels = set(bead.get("labels") or [])
    if labels & NAO_PENDENTE_EXATOS:
        return False
    return not any(l.startswith(NAO_PENDENTE_PREFIXOS) for l in labels)


def caixa_de_entrada(texto: str) -> str:
    """O que está digitado na caixa do prompt («❯ …» entre as duas réguas). Sem caixa achada → ""."""
    linhas = texto.splitlines()
    for i in range(len(linhas) - 1, -1, -1):
        l = linhas[i]
        if l.startswith("❯"):
            return l[1:].strip()
    return ""


def estado_da_tela(texto: str) -> str:
    """'ocupada' | 'pergunta' | 'digitando' | 'ociosa'."""
    if BUSY in texto:
        return "ocupada"
    if any(m in texto for m in PERGUNTA_ABERTA):
        return "pergunta"
    if caixa_de_entrada(texto):
        return "digitando"
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
        return json.loads((STATE_DIR / f"{nome}.json").read_text())
    except (OSError, ValueError):
        return {}


def gravar_estado(nome: str, st: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / f"{nome}.json").write_text(json.dumps(st))


def mail_mayor(assunto: str, corpo: str, dry: bool, run=rodar) -> None:
    if dry:
        log(f"DRY-RUN mail ao Mayor: {assunto}")
        return
    rc, _, _ = run(["gc", "mail", "send", "mayor/", "-s", assunto, "-m", corpo], timeout=60)
    if rc != 0:
        log(f"mail ao Mayor FALHOU ({assunto}) — avisar à mão")


def injetar(sess: str, texto: str, dry: bool, run=rodar) -> bool:
    if dry:
        log(f"DRY-RUN injetaria em {sess}: {texto[:90]}…")
        return True
    rc1, _, _ = run(["tmux", "send-keys", "-t", sess, "-l", texto], timeout=15)
    time.sleep(1)
    rc2, _, _ = run(["tmux", "send-keys", "-t", sess, "Enter"], timeout=15)
    return rc1 == 0 and rc2 == 0


# ───────────────────────────── passada ─────────────────────────────

def passada(dry: bool = False, run=rodar, agora=None) -> int:
    agora = agora or time.time()
    cego = ler_estado("_cego")
    sess_list = sessoes_tmux(run)
    lidos = {s: beads_em_andamento(s, run) for s in STORES if Path(s).is_dir()}
    if sess_list is None or all(v is None for v in lidos.values()):
        n = cego.get("passadas", 0) + 1
        gravar_estado("_cego", {"passadas": n, "avisado": cego.get("avisado", False)})
        log(f"NÃO SEI: tmux={'falhou' if sess_list is None else 'ok'}, stores ilegíveis — nenhuma injeção ({n} seguida(s))")
        if n >= BLIND_ALARM_PASSES and not cego.get("avisado"):
            mail_mayor("crew-idle-wake cego", f"{n} passadas seguidas sem ler tmux/beads: crew parada não seria acordada.", dry, run)
            gravar_estado("_cego", {"passadas": n, "avisado": True})
        return 0
    gravar_estado("_cego", {"passadas": 0, "avisado": False})
    beads = [b for v in lidos.values() if v for b in v]
    for store, v in lidos.items():
        if v is None:
            log(f"store ilegível nesta passada: {store} — sessões com bead nele ficam sem ordem nesta passada")
    injetadas = 0
    for sess in sess_list:
        if e_pool(sess):
            continue
        minhas = [b for b in beads if dono_da_sessao(sess, b.get("assignee", ""))]
        trabalho = [b["id"] for b in minhas if pendente(b)]
        st = ler_estado(sess)
        if not trabalho:
            if st:
                gravar_estado(sess, {})
            continue
        texto = tela(sess, run)
        if texto is None:
            log(f"{sess}: não li a tela — sem veredito")
            continue
        estado = estado_da_tela(texto)
        sig = assinatura(texto)
        # progresso de verdade = a bead andou (comentário, commit, troca de rótulo mexem no updated_at). A tela NÃO serve pra
        # isso: a própria ordem injetada muda a tela, e o teto de tentativas nunca dispararia.
        prog = max(str(b.get("updated_at") or "") for b in minhas if b["id"] in trabalho)
        if st.get("prog") != prog:
            st = {"prog": prog, "tentativas": 0, "avisado": False}
        if estado != "ociosa" or st.get("sig") != sig:
            # tela mudou (ou não está ociosa): só o relógio da ociosidade recomeça; as tentativas seguem até a bead andar
            st.update({"sig": sig, "desde": agora} if estado == "ociosa" else {"sig": None, "desde": agora})
            gravar_estado(sess, st)
            continue
        parado = agora - st.get("desde", agora)
        if parado < IDLE_MIN_SEC:
            continue
        if st.get("tentativas", 0) >= MAX_KICKS:
            if not st.get("avisado"):
                mail_mayor(f"crew {sess} não reage ao vigia (ga-esorlre.14)",
                           f"{sess} parada há {int(parado // 60)} min com {', '.join(trabalho)}; {MAX_KICKS} ordens no pane "
                           f"sem a bead andar. Confira com gc session peek {sess}.", dry, run)
                st["avisado"] = True
                gravar_estado(sess, st)
            continue
        msg = mensagem(trabalho, int(parado // 60))
        ok = injetar(sess, msg, dry, run)
        st["tentativas"] = st.get("tentativas", 0) + 1
        st["desde"] = agora          # a próxima tentativa só depois de mais IDLE_MIN_SEC parada
        gravar_estado(sess, st)
        log(f"{sess}: parada {int(parado // 60)} min com {', '.join(trabalho)} → ordem no pane "
            f"(tentativa {st['tentativas']}/{MAX_KICKS}, {'ok' if ok else 'send-keys FALHOU'})")
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
    passada(dry="--dry-run" in sys.argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
