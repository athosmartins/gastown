#!/usr/bin/env python3
"""gate-done-remote.py — o executável que o `gate-done` de uma sessão do servidor Hetzner roda NO MINI (ga-2hd02v.1.13).

Contents
  O que é · O que faz, em ordem · O que não faz · Códigos de saída · Modo de ensaio

O QUE É
  É o `gate_done_bin` do remote-shim-wrapper.py: o wrapper o executa quando a sessão remota roda `gate-done` (duas regras da lista, formas EXATAS: sem
  argumento, e `gate-done <bead> <ref> <sha>`), com a cidade como cwd e o ambiente montado do zero (BEADS_ACTOR = alias, mais a identidade que o servidor
  declarou e que casou com o identity_pattern). Antes dele o wrapper recusava (rc 77, "gate_done_bin ausente") e o Mayor submetia à mão.
  A forma com argumentos (ga-2hd02v.1.18) existe porque `worker/<sessão>` fica preso na 1ª entrega da sessão (o gate reescreve o branch e o push seguinte é
  não-fast-forward): a 2ª bead da sessão, e o conserto depois de uma reprovação, saem do ref que o dog diz, com o sha conferido.

O QUE FAZ, EM ORDEM (passo que não consegue saber algo para sem escrever nada: "não sei" nunca vira "pode")
  1. Quem pede: alias = BEADS_ACTOR, sessão = GC_SESSION_NAME. Os dois precisam ter o formato esperado E ser do mesmo papel (dog-remote, ps-worker-remote ou wa-worker-remote; nome sem papel vale como
     dog-remote): o identity_pattern do atalho é global, então a mistura passaria por ele. O PAPEL da sessão escolhe o rig (tabela RIGS) e, com ele, a loja da bead, o repositório do worktree e o espelho.
  2. A bead. Sem argumento: a ÚNICA bead in_progress atribuída ao alias na loja do rig dele (a cidade para o HQ); nenhuma, ou mais de uma → recusa (nunca adivinha qual submeter).
     Com argumentos, a que o dog NOMEOU (o prefixo dela tem de ser o do rig do papel): (A) in_progress com assignee = alias, ou (B) a VOLTA DO GATE: sem assignee, `gate:needs-fix`, gc.routed_to = a rota do pool do rig
     (gastown.dog no HQ, ps-worker, wa-worker: a que o dispatcher RESTAURA ao reprovar; medida em 3 beads do HQ) ou a do nó (posta à mão) e a última entrega (o marcador MAIS NOVO com source-bead:<bead>, de qualquer status) é deste alias, por gate.submitted_by OU pela linha `author:` do marcador
     (sem assignee o gate-done.md congela o CRIADOR em submitted_by; só o author guarda o alias). Sem marcador, leitura que falha ou ilegível → recusa.
  3. O trabalho: a ponta de `worker/<sessão>` no espelho do rig (<cidade>/.gc/hetzner-mirror/repos/<rig>.git; gascity para o HQ), onde o `git push` do servidor chegou. Com argumentos: a do
     <ref> (check_ref: `worker/<sessão>` ou `worker/<sessão>-N`, casamento EXATO com GC_SESSION_NAME, ou `fix/<bead>[-<resumo>]` com o id da bead pedida; o `-N` é
     recusado para sessão sem cauda, onde `<sessão>-N` pode ser OUTRA sessão), que tem de ser IGUAL ao <sha> (40 hex) que o dog diz, conferido ANTES do marcador.
     O nome `worker/<sessão>` não leva o id da bead e o gate extrai o id do nome do branch; por isso a submissão sai de um branch
     `fix/<bead>-<resumo>` no MESMO sha (o do próprio ref quando ele já é fix/…), criado num worktree descartável do mini, sob o caminho do rig (sem checkout: o gate-done só lê objetos).
  4. A submissão É o /gate-done: os blocos bash dos passos 1 a 4 de commands/gate-done.md são lidos DAQUI, a cada execução, e rodados juntos no worktree
     (push do branch, bead e rig, marcador, gate:queued, gate.submitted_by). Não há cópia deles neste arquivo: mudar o gate-done.md muda isto também.
     Se o arquivo mudar de forma (não achar exatamente um bloco bash por passo), nada é empurrado.
  5. Só depois do marcador, e só se `gate.submitted_by` aparece nele: solta a bead (tira `gc.routed_to`, depois o assignee, que só sai se ainda for o
     alias). Sem isso o pool do dog-remote recria uma sessão fresca a cada idle_timeout (15 min) enquanto a bead seguir atribuída ao alias (achado do
     dog-4 em ga-2hd02v.1.6). O guarda do gate faz o mesmo ao claimar; aqui é antes, para a janela não existir.
  6. Recolhe o que esta execução criou (worktree, branch local, ref temporária) e imprime o sha submetido. Nenhum git daqui dispara gc/manutenção.

O QUE NÃO FAZ
  Não vê o HEAD do servidor: sem argumento submete o que o ESPELHO tem em worker/<sessão> e imprime esse sha, e quem rodou o `gate-done` compara com
  `git rev-parse HEAD` (se diferir, o `git push origin HEAD` não chegou ou veio depois: empurre e rode de novo; o gate junta marcadores do mesmo branch). Com
  argumentos o dog passa o sha e a divergência é recusada antes do marcador. Em nenhuma forma ele confere se o ref empurrado é filho do que o origin já tem:
  isso é do passo 1 do gate-done.md (nunca força).
  Não roda o pre-push do WA (ga-2hd02v.3.10): o hook dele executa ~12 scripts da ÁRVORE empurrada (`$REPO_ROOT/scripts/check_*.py`, suítes pytest) e o worktree é sem checkout de propósito (nenhum código do nó roda no mini antes da revisão). Rig com
  `prepush=False` na tabela RIGS (hoje só o WA) roda os blocos do gate-done.md com core.hooksPath numa pasta vazia da cidade (por ambiente; o gate-done.md e a config do rig ficam como estão), e o aviso vai ao cliente e ao `self_audit:` do marcador. HQ e PS seguem com o hook.
  Não roda a checagem "NEW READS NEED A FAILURE TEST" nem a auto-auditoria do diff (são do construtor, antes do push): o marcador registra
  `self_audit: … auto-auditoria do diff NÃO verificada aqui`, visível, não calado.
  Só os rigs da tabela RIGS (gascity, property_scrapers, whatsapp_automation; ga-2hd02v.4): o PAPEL da sessão
  (dog-remote, ps-worker-remote, wa-worker-remote) decide o rig, e com ele a loja da bead, o repositório do worktree e o espelho; o PREFIXO da bead só é CONFERIDO contra o do rig do papel (alias e sessão de
  papéis diferentes, bead de outro prefixo, ou prefixo fora da tabela → recusa; nome de sessão que não é de nenhum papel vale como dog-remote, o comportamento de antes). O marcador do gate mora SEMPRE na loja da cidade; a bead, na do rig. Não força push: um branch fix/<bead>-… que já está no
  origin e não é ancestral do novo sha (histórico reescrito) é recusado pelo próprio passo 1 do gate-done.md.
  Se uma execução morrer no meio (kill do wrapper), sobra o worktree/branch: a próxima recusa e diz o que recolher (nunca apaga o que não criou).

CÓDIGOS DE SAÍDA (o wrapper devolve o do executável; 77 e 124-127 são DELE, e o stderr diz de quem é cada um)
  0 submetido (marcador criado; a linha `bead solta:` ou `AVISO:` diz se a bead foi solta) · 1 recusado ou falhou ANTES do marcador (a bead não mudou; um branch
  fix/… pode ter chegado ao origin) · 2 ambiente ou gate-done.md fora do esperado (nada foi escrito) · 4 o script terminou 0 sem UM marcador identificável (NÃO
  repita às cegas: `bd list -l type:quality-gate-marker -l source-bead:<bead>`).

MODO DE ENSAIO: `GATE_DONE_REMOTE_DRY_RUN=1` resolve tudo (alias, bead, sha, branch, blocos) e imprime o plano; não cria worktree, não empurra, não escreve.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import NamedTuple

ALIAS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SESS_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,60}")  # o formato que o `wt-add` aceita: é dele que vem o nome do branch worker/<sessão>
BEAD_RE = re.compile(r"[a-z]{2,8}-[a-z0-9]{2,16}(?:\.[0-9]{1,4}){0,3}")  # o id que o passo 2 do gate-done.md extrai do nome do branch (se divergirem, ELE recusa)
MARKER_RE = re.compile(r"^Marker created: (\S+)\s*$", re.M)
SHA_RE = re.compile(r"[0-9a-f]{40}")  # o sha que o dog diz: inteiro, para a conferência com o espelho ser igualdade e não prefixo
USAGE = "gate-done <bead> <ref> <sha>   (ou `gate-done` sem argumento: a ÚNICA bead in_progress do alias, de worker/<sessão>)"
FIX_LABEL = "gate:needs-fix"  # o que o dispatcher põe na bead-fonte quando o gate reprova: a "volta do gate"
ROUTES = ("gastown.dog", "dog-remote")  # (rig gascity; os outros: RIGS) gc.routed_to de uma volta do gate: gastown.dog é o que o dispatcher RESTAURA ao reprovar (gate_fail_restore_route → default_pool_route_for_rig; medido em ga-9636op, ga-2hd02v.1.12 e .1.18); dog-remote é a rota posta à mão. Quem prova que a bead é DESTE alias é a última entrega, não a rota
BARE_ROLE_RE = re.compile(r"(?:dog|gate-reviewer|wa-worker|ps-worker)-remote")  # nome de sessão SEM cauda: pelo IDENTITY_PATTERN (gc-session-ssh.md) `<papel>-remote-<1-3 dígitos>` TAMBÉM é nome válido de sessão
TIMEOUT_CMD = 120  # um bd/git que pendura não segura a submissão para sempre (o wrapper também corta tudo em timeout_s)
SCRIPT_RAN = [False]  # vira True quando os blocos do gate-done.md começam: daí em diante um erro NÃO é "nada foi escrito" (marcador pode existir)


class Rig(NamedTuple):
    prefix: str    # prefixo do id da bead (ga-…, ps-…): é ele que diz em que loja a bead mora
    name: str      # nome do rig = nome do espelho (<cidade>/.gc/hetzner-mirror/repos/<name>.git) e da pasta do rig
    role: str      # o papel das sessões remotas que submetem DESTE rig (a parte do nome da sessão antes do sufixo)
    routes: tuple  # gc.routed_to de uma volta do gate neste rig: o pool do mini (o que o dispatcher RESTAURA ao reprovar) e o do nó
    prepush: bool = True  # False = o pre-push do rig NÃO roda no mini (ga-2hd02v.3.10): ele executa scripts da ÁRVORE empurrada, e o worktree é sem checkout de propósito (código do nó não roda no mini antes da revisão)


# ga-2hd02v.4: a tabela do que o atalho atende. Rig fora dela = recusa (nunca "tenta e vê").
RIGS = {
    "ga": Rig("ga", "gascity", "dog-remote", ROUTES),
    "ps": Rig("ps", "property_scrapers", "ps-worker-remote", ("ps-worker", "ps-worker-remote")),
    "wa": Rig("wa", "whatsapp_automation", "wa-worker-remote", ("wa-worker", "wa-worker-remote"), prepush=False),  # medido 22/10: ~12 dos ~15 guards do pre-push do WA rodam arquivos de $REPO_ROOT (a árvore empurrada); HQ e PS seguem com o hook (PS: só um shim do bd)
}
ROLE_RE = re.compile(r"(dog-remote|ps-worker-remote|wa-worker-remote)(?:-|$)")  # o papel de um nome de sessão; gate-reviewer-remote e nomes de teste não casam → vale o rig do HQ, como antes


class Ctx(NamedTuple):
    rig: Rig
    store: str     # pasta para `bd -C`: a loja onde a bead mora (a cidade para o HQ; o rig para os outros)
    repo: str      # repositório git de onde sai o worktree descartável
    mirror: str    # espelho bare com worker/<sessão>
    wt_base: str   # pasta onde nasce o worktree descartável (sob o caminho do rig: o gate-done.md acha o rig pelo caminho do cwd)


class Stop(Exception):
    def __init__(self, msg: str, rc: int = 1):
        super().__init__(msg)
        self.rc = rc


def say(msg: str) -> None:
    print(f"gate-done-remote: {msg}", file=sys.stderr, flush=True)


def run(cmd: list, timeout: int = TIMEOUT_CMD) -> subprocess.CompletedProcess:
    """Sem shell. Não levanta: comando que não rodou ou pendurou vira rc 255 com o motivo no stderr (quem chama decide; nunca lido como sucesso vazio)."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(cmd, 255, "", f"{type(e).__name__}: {e}")


def bd_json(city: str, args: list, what: str):
    # vazio → devolve o que o bd mandou (lista vazia é resposta); falhou/ilegível → Stop: nunca vira "não há"
    r = run(["bd", "-C", city] + args)
    if r.returncode != 0:
        raise Stop(f"não consegui ler {what} (bd rc={r.returncode}: {r.stderr.strip()[:120]})")
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        raise Stop(f"{what}: resposta do bd ilegível ({e})")


def first(doc):  # `bd show --json` devolve uma lista de 1; aceita o objeto solto também
    return doc[0] if isinstance(doc, list) and doc else doc


def slugify(title: str) -> str:
    t = unicodedata.normalize("NFKD", title or "").encode("ascii", "ignore").decode()
    t = re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")
    return t[:40].rstrip("-") or "remote"


def one_bead(city: str, alias: str) -> dict:
    # (city = a pasta da loja da bead) vazio ([]) → Stop "nenhuma bead"; falhou/ilegível → Stop do bd_json; duas ou mais → Stop: a submissão nunca escolhe
    rows = bd_json(city, ["list", "--status", "in_progress", "--assignee", alias, "--json", "--limit", "0"], f"as beads in_progress de {alias}")
    if not isinstance(rows, list) or not all(isinstance(x, dict) and isinstance(x.get("id"), str) for x in rows):
        raise Stop(f"beads de {alias}: resposta do bd com forma inesperada")
    if not rows:
        raise Stop(f"nenhuma bead in_progress atribuída a {alias}: não sei o que submeter")
    if len(rows) > 1:
        raise Stop(f"{len(rows)} beads in_progress atribuídas a {alias} ({', '.join(x['id'] for x in rows[:5])}): não adivinho qual submeter")
    if not BEAD_RE.fullmatch(rows[0]["id"]):
        raise Stop(f"id da bead {rows[0]['id']!r} fora do formato que o gate-done aceita no nome do branch")
    return rows[0]


def check_ref(raw: str, sess: str, bid: str) -> str:
    """O branch do espelho que o dog pede para submeter, sem `refs/heads/`. Só vale o que é DESTA sessão (worker/<sessão> ou worker/<sessão>-N: casamento
    EXATO, nunca prefixo, senão a sessão `x4` passaria por `x`) ou leva o id da bead pedida (fix/<bead> ou fix/<bead>-<resumo>). Qualquer outra coisa → Stop (nada foi lido
    nem escrito). Função pura: a identidade vem do ambiente do atalho (GC_SESSION_NAME), nunca do que o dog escreve."""
    name = raw[len("refs/heads/"):] if raw.startswith("refs/heads/") else raw
    mine = re.fullmatch(rf"worker/{re.escape(sess)}(?:-[0-9]{{1,3}})?", name)
    fixed = re.fullmatch(rf"fix/{re.escape(bid)}(?:-[A-Za-z0-9._-]{{1,80}})?", name)
    if not (mine or fixed):
        raise Stop(f"{raw[:80]!r} está fora do que esta sessão pode submeter (worker/{sess} ou worker/{sess}-N, ou fix/{bid} / fix/{bid}-<resumo>)")
    if mine and not fixed and name != f"worker/{sess}" and BARE_ROLE_RE.fullmatch(sess):  # `-N` só é inequívoco se `<sessão>-N` NÃO for ele mesmo nome de sessão (revisão lateral, ga-2hd02v.1.18)
        raise Stop(f"{name!r}: a sessão {sess!r} não tem cauda, então worker/{sess}-N pode ser o branch principal de OUTRA sessão ({sess}-N é nome válido): empurre fix/{bid}-<resumo> e submeta esse ref")
    if run(["git", "check-ref-format", f"refs/heads/{name}"]).returncode != 0:
        raise Stop(f"{name!r} não é um nome de branch válido")
    return name


def last_delivery(city: str, bid: str) -> dict:
    """O marcador MAIS NOVO da bead (a última entrega ao gate), de qualquer status: os fechados contam. Lista vazia → Stop (nunca foi entregue: não há volta do gate);
    marcador sem created_at → Stop (não sei qual é o mais novo); leitura que falha/ilegível → Stop do bd_json. Nunca 'não achei' = 'pode'."""
    rows = bd_json(city, ["list", "--all", "--label", "type:quality-gate-marker", "--label", f"source-bead:{bid}", "--json", "--limit", "0"], f"os marcadores de {bid}")
    if not isinstance(rows, list) or not all(isinstance(x, dict) and isinstance(x.get("created_at"), str) and x["created_at"] for x in rows):
        raise Stop(f"marcadores de {bid}: resposta do bd com forma inesperada (sem created_at?)")
    if not rows:
        raise Stop(f"{bid} nunca foi entregue ao gate (nenhum marcador source-bead:{bid}): não há volta do gate para submeter")
    return max(rows, key=lambda x: (x["created_at"], str(x.get("id", ""))))


def delivered_by(marker: dict, alias: str) -> bool:
    """A entrega é deste alias? `gate.submitted_by` (congelado pelo gate-done.md: assignee→created_by→owner) OU a linha `author:` da descrição (o GC_ALIAS de quem rodou o
    gate-done): numa volta do gate a bead não tem assignee, então a 2ª entrega congela o CRIADOR em submitted_by e só o `author:` guarda o alias."""
    meta, desc = marker.get("metadata"), marker.get("description")
    by = meta.get("gate.submitted_by") if isinstance(meta, dict) else None
    m = re.search(r"^author: (\S+)\s*$", desc if isinstance(desc, str) else "", re.M)
    return alias in {by, m.group(1) if m else None}


def named_bead(city: str, alias: str, bid: str, store: str = "", routes: tuple = ROUTES) -> dict:
    """A bead que o dog NOMEOU. Vale em dois casos: (A) in_progress com assignee = alias; (B) volta do gate: sem assignee, `gate:needs-fix`, gc.routed_to = a rota que o gate restaura
    (gastown.dog no HQ; ps-worker/wa-worker nos rigs) ou a do nó (à mão) e a última entrega (marcador mais novo, na loja da CIDADE) é deste alias. `store` = a loja da bead (padrão: a cidade).
    Ausente, forma outra, ou leitura que falha/ilegível → Stop (bd_json), nunca 'pode'."""
    bead = first(bd_json(store or city, ["show", bid, "--json"], f"a bead {bid}"))
    if not isinstance(bead, dict) or bead.get("id") != bid:
        raise Stop(f"a bead {bid}: resposta do bd com forma inesperada")
    if bead.get("status") == "in_progress" and bead.get("assignee") == alias:
        return bead
    labels, meta = bead.get("labels"), bead.get("metadata")
    back = (bead.get("status") in ("open", "in_progress") and not bead.get("assignee") and isinstance(labels, list) and FIX_LABEL in labels
            and isinstance(meta, dict) and meta.get("gc.routed_to") in routes)  # rota ausente ou de outro pool → não é volta (nunca "sem rota" = "pode")
    if not back:
        raise Stop(f"{bid} não é uma bead in_progress atribuída a {alias} (status={bead.get('status')!r}, assignee={bead.get('assignee')!r}) nem uma volta do gate "
                   f"(sem assignee, com {FIX_LABEL} e gc.routed_to em {'/'.join(routes)}; achei {(meta.get('gc.routed_to') if isinstance(meta, dict) else None)!r}): não submeto bead alheia")
    last = last_delivery(city, bid)
    if not delivered_by(last, alias):
        who = (last.get("metadata") or {}).get("gate.submitted_by") if isinstance(last.get("metadata"), dict) else None
        raise Stop(f"a última entrega de {bid} (marcador {last.get('id')}, submitted_by={who!r}) não foi de {alias}: não submeto o conserto de outra sessão")
    return bead


def mirror_sha(mirror: str, src: str, rig: str = "gascity") -> str:
    # vazio (a ref não existe, rc 1) → Stop "o push não chegou"; falhou/ilegível (espelho ausente, git que não leu) → Stop com o rc
    if not os.path.isdir(mirror):
        raise Stop(f"espelho {mirror} não existe neste mini")
    r = run(["git", f"--git-dir={mirror}", "rev-parse", "--verify", "-q", f"refs/heads/{src}^{{commit}}"])
    sha = r.stdout.strip()
    if r.returncode == 1 and not sha:
        raise Stop(f"o espelho não tem {src}: o `git push origin HEAD:refs/heads/{src}` do servidor não chegou (ou a sessão é de outro rig; este espelho é o do {rig})")
    if r.returncode != 0 or not SHA_RE.fullmatch(sha):
        raise Stop(f"não consegui ler {src} no espelho (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    return sha


def gate_done_script(md: Path) -> str:
    # falhou/ilegível (arquivo ausente ou não UTF-8) → Stop rc 2; vazio de blocos ou forma outra que 1 bloco por passo → Stop rc 2. Nada foi escrito ainda.
    try:
        lines = md.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as e:
        raise Stop(f"não consegui ler {md}: {e}", 2)
    blocks: dict = {}
    step, cur = None, None
    for ln in lines:
        if cur is None and ln.startswith("## "):
            m = re.match(r"^## Step (\d+)\b", ln)
            step = int(m.group(1)) if m else None
        if cur is None and step in (1, 2, 3, 4) and ln.strip() == "```bash":
            cur = []
        elif cur is not None and ln.strip() == "```":
            blocks.setdefault(step, []).append("\n".join(cur))
            cur = None
        elif cur is not None:
            cur.append(ln)
    if cur is not None or sorted(blocks) != [1, 2, 3, 4] or any(len(v) != 1 for v in blocks.values()):
        got = ", ".join(f"passo {k}: {len(v)}" for k, v in sorted(blocks.items())) or "nenhum"
        raise Stop(f"{md.name} mudou de forma (esperado exatamente 1 bloco bash em cada passo 1-4; achei {got}): não sei montar a submissão", 2)
    return "\n".join(blocks[i][0] for i in (1, 2, 3, 4)) + "\n"


def release(city: str, bead: str, alias: str, marker: str, store: str = "") -> None:
    """Solta a bead do pool DEPOIS do marcador (o marcador é lido na CIDADE; a bead é escrita e conferida em `store`, a loja dela; padrão: a cidade).
    Leitura que falha ou vem sem gate.submitted_by → não solta e diz (o guarda do gate a solta ao claimar)."""
    store = store or city
    try:
        # vazio (sem gate.submitted_by) → não solta; falhou/ilegível → não solta
        who = ((first(bd_json(city, ["show", marker, "--json"], f"o marcador {marker}")) or {}).get("metadata") or {}).get("gate.submitted_by")
    except (Stop, AttributeError, TypeError) as e:
        print(f"AVISO: não soltei {bead}: não consegui ler o marcador {marker} ({e}); o guarda do gate a solta ao claimar", flush=True)
        return
    if not who:
        print(f"AVISO: não soltei {bead}: {marker} não tem gate.submitted_by (soltar agora faria o guarda atribuir o autor ao criador da bead); o guarda do gate a solta ao claimar", flush=True)
        return
    a = run(["bd", "-C", store, "update", bead, "--unset-metadata", "gc.routed_to", "--unset-metadata", "pilot.wa_node_alias", "-q"])  # a rota primeiro (e a marca pilot.wa_node_alias do modo em que o Pilot abre a sessão e não grava rota — ga-2hd02v.3; tirar chave que não existe não falha, medido com o bd real): sem elas nenhuma sonda reclama a bead
    b = run(["bd", "-C", store, "update", bead, "--if-assignee", alias, "-a", "", "-q"])  # só sai se AINDA for o alias: outro dono não é tirado
    try:
        # confere o EFEITO, não o rc: lida e sem dono/rota/marca → solta; falhou/ilegível OU lista vazia/outra bead (o bd não devolveu a bead) → "?" = não sei, dito como aviso — nunca "solta"
        now = first(bd_json(store, ["show", bead, "--json"], f"a bead {bead}"))
        if not isinstance(now, dict) or now.get("id") != bead:
            raise Stop(f"o bd não devolveu a bead {bead} ao reler")
        left = [k for k, v in (("assignee", now.get("assignee")), ("gc.routed_to", (now.get("metadata") or {}).get("gc.routed_to")), ("pilot.wa_node_alias", (now.get("metadata") or {}).get("pilot.wa_node_alias"))) if v]
    except (Stop, AttributeError, TypeError):
        left = ["?"]
    if left:
        print(f"AVISO: {bead} NÃO ficou solta (resta {', '.join(left)}; unset rc={a.returncode}, assignee rc={b.returncode}); o guarda do gate a solta ao claimar", flush=True)
    else:
        print(f"bead solta: {bead} sem assignee e sem gc.routed_to", flush=True)


def hooks_off(env: dict, work: Path) -> dict:
    """O ambiente dos blocos do gate-done.md SEM hooks do git: core.hooksPath → uma pasta vazia da cidade (a trava mora ao lado), por GIT_CONFIG_* (a config de linha de comando vence a do repositório, que aponta para o hook do rig).
    Em vez de editar o gate-done.md ou injetar `--no-verify` no texto dele: o push do passo 1 segue idêntico, só que sem hook, e nenhum arquivo da árvore do nó roda no mini."""
    nohooks = work / "no-hooks"
    # vazio (pasta sem nada) → segue; achou arquivo (um hook plantado) ou pasta que não dá para criar/ler → Stop: o pre-push alheio rodaria NO MINI antes do marcador (nada foi escrito)
    try:
        nohooks.mkdir(parents=True, exist_ok=True, mode=0o700)
        found = sorted(os.listdir(nohooks))
    except OSError as e:
        raise Stop(f"não consegui criar/ler a pasta sem hooks {nohooks} ({type(e).__name__}): não submeto")
    if found:
        raise Stop(f"a pasta sem hooks {nohooks} não está vazia ({', '.join(found[:3])}): um hook plantado rodaria no mini; esvazie à mão")
    # vazio (nenhum GIT_CONFIG_COUNT) → 0; ilegível (não é número) → Stop: sem o índice certo eu sobrescreveria a config que o main() já pôs (gc.auto, maintenance.auto)
    try:
        n = int(env.get("GIT_CONFIG_COUNT") or "0")
        if n < 0:
            raise ValueError(n)
    except ValueError:
        raise Stop(f"GIT_CONFIG_COUNT={env.get('GIT_CONFIG_COUNT')!r} ilegível: não sei onde acrescentar core.hooksPath")
    return {**env, "GIT_CONFIG_COUNT": str(n + 1), f"GIT_CONFIG_KEY_{n}": "core.hooksPath", f"GIT_CONFIG_VALUE_{n}": str(nohooks)}


def submit(city: str, ctx: Ctx, alias: str, sess: str, bid: str, sha: str, src: str, branch: str, script: str) -> int:
    repo, mirror = ctx.repo, ctx.mirror
    work = Path(city) / ".gc" / "gate-done-remote"    # a trava mora na cidade; o worktree, sob o caminho do rig (HQ: a mesma pasta de antes)
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(work / f"{bid}.lock", "a")
    wtd = Path(ctx.wt_base)
    wtd.mkdir(parents=True, exist_ok=True, mode=0o700)
    wt, ref = str(wtd / f"wt-{bid}"), f"refs/gt-remote/{sess}"
    made_wt = made_ref = False
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise Stop(f"outra submissão de {bid} está em curso (trava {work / (bid + '.lock')})")
        # vazio (nenhuma ref com esse nome) → segue; achou ref ou pasta sobrando → Stop (resto de execução morta, pode ser de outra mão: não apago);
        # falhou (git rc != 0) → Stop: sem saber se há um branch alheio com o nome, não crio o meu
        refs = run(["git", "-C", repo, "for-each-ref", "--format=%(refname)", f"refs/heads/{branch}"])
        if refs.returncode != 0:
            raise Stop(f"não consegui listar os branches locais (git rc={refs.returncode}: {refs.stderr.strip()[:100]})")
        if os.path.exists(wt) or refs.stdout.strip():
            raise Stop(f"resto de uma submissão anterior ({wt} ou o branch local {branch}): recolha à mão antes (git worktree remove --force; git branch -D)")
        made_ref = True  # daqui em diante a ref temporária é desta execução (antes disso ela pode ser de quem segura a trava)
        r = run(["git", "-C", repo, "fetch", "-q", "--no-tags", "--no-write-fetch-head", mirror, f"+refs/heads/{src}:{ref}"], timeout=240)
        if r.returncode != 0:
            raise Stop(f"não consegui buscar {src} do espelho (git rc={r.returncode}: {r.stderr.strip()[:160]})")
        r = run(["git", "-C", repo, "worktree", "add", "-q", "--no-checkout", "-b", branch, wt, sha], timeout=240)
        if r.returncode != 0:
            raise Stop(f"não consegui criar o worktree de {branch} em {sha[:12]} (git rc={r.returncode}: {r.stderr.strip()[:160]})")
        made_wt = True
        head = run(["git", "-C", wt, "rev-parse", "HEAD"]).stdout.strip()
        if head != sha:  # o que vai ao gate tem de ser exatamente o que o espelho tinha
            raise Stop(f"o worktree ficou em {head[:12]!r}, não em {sha[:12]}")
        env = {**os.environ, "GC_CITY_PATH": city, "GC_ALIAS": os.environ.get("GC_ALIAS", alias), "GIT_TERMINAL_PROMPT": "0",
               "SELF_AUDIT_SUMMARY": f"submetido pelo atalho remoto (gate-done-remote.py) em nome de {alias}, sessão {sess}, ref {src}, sha {sha[:12]}; auto-auditoria do diff NAO verificada aqui"}
        if not ctx.rig.prepush:  # o aviso vai ao cliente E ao marcador (self_audit:, o que o revisor do gate lê): pular o hook nunca fica calado
            env = hooks_off(env, work)
            env["SELF_AUDIT_SUMMARY"] += f"; ATENCAO: o pre-push de {ctx.rig.name} NAO rodou no mini (executaria codigo do no antes da revisao): os guards dele nao foram verificados"
            say(f"AVISO: o pre-push de {ctx.rig.name} NÃO roda no mini (ele executaria scripts da árvore do nó antes da revisão); o marcador registra isso em self_audit")
        SCRIPT_RAN[0] = True
        p = subprocess.run(["bash", "-c", script], cwd=wt, env=env, stdout=subprocess.PIPE, text=True, errors="replace")  # o stderr do script segue direto ao cliente
        print(p.stdout, end="", flush=True)
        if p.returncode != 0:
            raise Stop(f"os blocos do gate-done.md saíram {p.returncode}: nenhum marcador criado; veja as linhas acima")
        found = MARKER_RE.findall(p.stdout)
        if len(found) != 1:
            say(f"ATENÇÃO: o script saiu 0 mas vi {len(found)} linha(s) 'Marker created': NÃO repita às cegas, confira os marcadores de {bid}")
            return 4
        release(city, bid, alias, found[0], ctx.store)
        print(f"submetido: {branch} @ {sha} (marcador {found[0]}); confira com `git rev-parse HEAD` no servidor", flush=True)
        return 0
    finally:  # recolhe só o que ESTA execução criou; falha aqui é aviso (o resultado já foi dito acima)
        steps = ([["git", "-C", repo, "worktree", "remove", "--force", wt], ["git", "-C", repo, "branch", "-D", branch]] if made_wt else []) \
            + ([["git", "-C", repo, "update-ref", "-d", ref]] if made_ref else [])
        for cmd in steps:
            r = run(cmd)
            if r.returncode != 0:
                say(f"AVISO: não recolhi ({' '.join(cmd[3:6])}): {r.stderr.strip()[:120]}")
        lock.close()


def rig_of_session(sess: str) -> str:
    """O prefixo do rig de uma sessão pelo PAPEL no nome (dog-remote-…, ps-worker-remote-…, wa-worker-remote-…). Papel que não casa (gate-reviewer-remote, nome de teste) → "ga": o HQ, como antes da tabela."""
    m = ROLE_RE.match(sess)
    return next((p for p, r in RIGS.items() if m and r.role == m.group(1)), "ga")


def rig_ctx(city: str, prefix: str, mirror_override: str = "") -> Ctx:
    """A loja, o repositório, o espelho e a pasta de worktree do rig. Prefixo fora da tabela, rota ausente ou ilegível, pasta que não existe, repositório que o git não lê → Stop (nada foi escrito)."""
    rig = RIGS.get(prefix)
    if rig is None:
        raise Stop(f"prefixo {prefix!r} fora da tabela de rigs do atalho ({', '.join(sorted(RIGS))}): não submeto")
    if prefix == "ga":
        # vazio/falhou (git não achou o repositório da cidade) → Stop: sem repositório não há onde criar o worktree
        top = run(["git", "-C", city, "rev-parse", "--show-toplevel"])
        if top.returncode != 0 or not top.stdout.strip():
            raise Stop(f"não achei o repositório da cidade (git rc={top.returncode}: {top.stderr.strip()[:100]})")
        return Ctx(rig, city, top.stdout.strip(), mirror_override or f"{city}/.gc/hetzner-mirror/repos/{rig.name}.git", str(Path(city) / ".gc" / "gate-done-remote"))
    # vazio (prefixo sem rota) → Stop; falhou/ilegível (routes.jsonl ausente, linha que não é JSON) → Stop: sem a rota não sei onde a bead mora
    try:
        rows = [json.loads(l) for l in (Path(city) / ".beads" / "routes.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        rel = next(r["path"] for r in rows if r.get("prefix") == prefix)
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as e:
        raise Stop(f"não achei a rota do prefixo {prefix!r} em {city}/.beads/routes.jsonl ({type(e).__name__}): sem ela não sei em que loja a bead mora")
    path = os.path.realpath(os.path.join(city, rel))
    if os.path.basename(path) != rig.name or not os.path.isdir(path):
        raise Stop(f"a rota do prefixo {prefix!r} aponta para {path}, que não é a pasta do rig {rig.name}: não submeto")
    g = run(["git", "-C", path, "rev-parse", "--git-dir"])
    if g.returncode != 0:
        raise Stop(f"o git não lê o repositório do rig {rig.name} em {path} (rc={g.returncode}: {g.stderr.strip()[:100]})")
    return Ctx(rig, path, path, f"{city}/.gc/hetzner-mirror/repos/{rig.name}.git", str(Path(path) / ".gc-worktrees" / "gate-done-remote"))


def main() -> int:
    city = os.path.realpath(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    if os.path.realpath(os.getcwd()) != city:  # o wrapper roda com cwd = cidade; outro cwd é uso fora do desenho
        raise Stop(f"cwd {os.getcwd()} não é a cidade {city}: este executável é chamado pelo remote-shim-wrapper (ensaio: cd na cidade)", 2)
    alias, sess = os.environ.get("BEADS_ACTOR", ""), os.environ.get("GC_SESSION_NAME", "")
    if not ALIAS_RE.fullmatch(alias) or not SESS_RE.fullmatch(sess):
        raise Stop(f"BEADS_ACTOR={alias[:40]!r} / GC_SESSION_NAME={sess[:40]!r} fora do formato: sem saber quem pede não submeto", 2)
    # nenhum git desta submissão (nem os do gate-done.md) dispara gc/manutenção no repositório compartilhado: o disco do mini vive no piso do heavy-guard (ga-vln2py)
    os.environ.update({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0", "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false"})
    mirror = os.environ.get("GATE_DONE_REMOTE_MIRROR") or ""  # só vale para o rig do HQ (teste); os outros rigs usam sempre o espelho do próprio nome
    role_prefix = rig_of_session(sess)
    # o identity_pattern do atalho é GLOBAL (casa os quatro papéis), então alias de um papel com sessão de outro passa por ele: aqui o alias e a sessão têm de ser do MESMO papel (nome sem papel vale como o HQ nos dois)
    if rig_of_session(alias) != role_prefix:
        raise Stop(f"identidade mista: o alias {alias!r} é do rig {RIGS[rig_of_session(alias)].name} e a sessão {sess!r} é do rig {RIGS[role_prefix].name}: não submeto", 2)
    args = sys.argv[1:]
    want = None
    if args:  # forma com argumentos: o dog diz a bead, o ref do espelho e o sha (ga-2hd02v.1.18); nada é lido antes de a forma e o ref passarem
        if len(args) != 3 or not BEAD_RE.fullmatch(args[0]) or not SHA_RE.fullmatch(args[2]):
            raise Stop(f"forma: {USAGE} (o sha inteiro, 40 hex: `git rev-parse HEAD`)", 2)
        want = args[2]
        src = check_ref(args[1], sess, args[0])
        bpfx = args[0].split("-", 1)[0]
        if bpfx != role_prefix:  # a sessão de um papel só submete bead do rig do papel (bead alheia nem é lida)
            raise Stop(f"a sessão {sess} é do rig {RIGS[role_prefix].name} e {args[0]} é de outro prefixo ({bpfx}): não submeto")
        ctx = rig_ctx(city, role_prefix, mirror)
        bead = named_bead(city, alias, args[0], ctx.store, ctx.rig.routes)
    else:
        ctx = rig_ctx(city, role_prefix, mirror)
        bead = one_bead(ctx.store, alias)
        src = f"worker/{sess}"
    bid = bead["id"]
    if bid.split("-", 1)[0] != role_prefix:  # a lista da loja do rig só devolve bead dele; se não for, algo está errado e eu não submeto
        raise Stop(f"a bead {bid} não é do rig {ctx.rig.name} (prefixo {role_prefix}): não submeto")
    sha = mirror_sha(ctx.mirror, src, ctx.rig.name)
    if want is not None and sha != want:  # antes do marcador: o gate nunca recebe um sha que o dog não disse
        raise Stop(f"o espelho tem {sha[:12]} em {src}, mas você disse {want[:12]}: o push não chegou ou veio depois; empurre de novo (git push origin HEAD:refs/heads/{src}) e repita. Nada foi submetido")
    branch = src if src.startswith("fix/") else f"fix/{bid}-{slugify(bead.get('title', ''))}"  # o nome no origin SEMPRE leva o id da bead (o gate o extrai dele); worker/… não leva
    if run(["git", "check-ref-format", "--branch", branch]).returncode != 0:
        raise Stop(f"{branch!r} não é um nome de branch válido")
    script = gate_done_script(Path(city) / "commands" / "gate-done.md")
    print(f"gate-done-remote: alias={alias} sessão={sess} bead={bid} {src}@{sha[:12]} → {branch}", flush=True)
    if os.environ.get("GATE_DONE_REMOTE_DRY_RUN") == "1":
        print(f"ensaio: nada foi escrito (blocos do gate-done.md: {len(script.splitlines())} linhas)", flush=True)
        return 0
    return submit(city, ctx, alias, sess, bid, sha, src, branch, script)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Stop as e:
        say(f"RECUSADO: {e}")
        sys.exit(e.rc)
    except Exception as e:  # o que não previ: antes do script nada foi escrito (1); depois dele o marcador pode existir (4, não repita às cegas)
        if SCRIPT_RAN[0]:
            say(f"ATENÇÃO: erro interno depois de iniciar a submissão ({type(e).__name__}: {e}); o marcador pode existir — NÃO repita às cegas")
            sys.exit(4)
        say(f"RECUSADO: erro interno {type(e).__name__}: {e}")
        sys.exit(1)
