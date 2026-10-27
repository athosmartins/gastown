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
  3. O trabalho, no espelho do rig (<cidade>/.gc/hetzner-mirror/repos/<rig>.git; gascity para o HQ), onde o `git push` do servidor chegou. Sem argumento (pick_ref): entre os
     `worker/<sessão>` e `worker/<sessão>-<cauda>` (`-v2`, `-<bead>`; a cauda é recusada para sessão sem cauda, onde `<sessão>-<cauda>` pode ser OUTRA sessão) fica o que tem commit PRÓPRIO
     (que refs/remotes/origin/main do espelho não tem) citando a bead; o que já está no main, ou cita só outra bead, é ignorado com a razão dita; vários que citam → o que contém os outros; se nenhum contém os outros (o worker deu amend/rebase e o espelho,
     que só avança por FF, guardou a versão nova em OUTRO ref) vale o de commit mais novo, dito na saída com a forma de trocar; empate de hora ou hora ilegível recusa. Nunca o ref fixo `worker/<sessão>` às cegas: ele fica preso na entrega anterior (ga-2hd02v.3.13). Com argumentos: a do
     <ref> (check_ref: `worker/<sessão>` ou `worker/<sessão>-<cauda>`, casamento EXATO com GC_SESSION_NAME, ou `fix/<bead>[-<resumo>]` com o id da bead pedida), que tem de ser IGUAL ao <sha> (40 hex) que
     o dog diz, conferido ANTES do marcador, e passa pela mesma prova do commit que cita a bead (regra do guarda ga-pj5va; no ensaio também).
     O nome `worker/<sessão>` não leva o id da bead e o gate extrai o id do nome do branch; por isso a submissão sai de um branch
     `fix/<bead>-<resumo>` no MESMO sha (o do próprio ref quando ele já é fix/…), criado num worktree descartável do mini, sob o caminho do rig (sem checkout: o gate-done só lê objetos).
  3b. O fix/<bead>-… que o origin já tem (lease_push, antes de qualquer escrita no banco): ausente, igual ao sha ou ancestral dele → o passo 1 empurra como sempre. Não-FF (o dispatcher rebaseou) →
     busca o branch e o main do origin em refs temporárias e só empurra se NADA se perde (`rev-list --right-only --cherry-pick`: todo commit do origin já está no main ou existe no sha como patch
     equivalente), com --force-with-lease=<ref>:<sha lido>; senão recusa dizendo para refazer sobre o que o origin tem. Nunca força às cegas.
  4. A submissão É o /gate-done: os blocos bash dos passos 1 a 4 de commands/gate-done.md são lidos DAQUI, a cada execução, e rodados juntos no worktree
     (push do branch, bead e rig, marcador, gate:queued, gate.submitted_by). Não há cópia deles neste arquivo: mudar o gate-done.md muda isto também.
     Se o arquivo mudar de forma (não achar exatamente um bloco bash por passo), nada é empurrado.
  5. Só depois do marcador, e só se `gate.submitted_by` aparece nele: solta a bead (tira `gc.routed_to`, depois o assignee, que só sai se ainda for o
     alias). Sem isso o pool do dog-remote recria uma sessão fresca a cada idle_timeout (15 min) enquanto a bead seguir atribuída ao alias (achado do
     dog-4 em ga-2hd02v.1.6). O guarda do gate faz o mesmo ao claimar; aqui é antes, para a janela não existir.
  6. Recolhe o que esta execução criou (worktree, branch local, ref temporária, pasta temporária dos guards) e imprime o sha submetido. Nenhum git daqui dispara gc/manutenção.

O QUE NÃO FAZ
  Não vê o HEAD do servidor: sem argumento submete o que o ESPELHO tem no ref escolhido (worker/<sessão>[-<cauda>]) e imprime esse sha, e quem rodou o `gate-done` compara com
  `git rev-parse HEAD` (se diferir, o `git push origin HEAD` não chegou ou veio depois: empurre e rode de novo; o gate junta marcadores do mesmo branch). Com
  argumentos o dog passa o sha e a divergência é recusada antes do marcador. O que está no servidor e não chegou ao espelho ele não vê.
  Não roda o pre-push do WA (ga-2hd02v.3.10): o hook dele executa ~12 scripts da ÁRVORE empurrada (`$REPO_ROOT/scripts/check_*.py`, suítes pytest) e o worktree é sem checkout de propósito (nenhum código do nó roda no mini antes da revisão). Rig com
  `prepush=False` na tabela RIGS (hoje só o WA) roda os blocos do gate-done.md com core.hooksPath numa pasta vazia da cidade (por ambiente; o gate-done.md e a config do rig ficam como estão), e o aviso vai ao cliente e ao `self_audit:` do marcador. HQ e PS seguem com o hook.
  Em troca (ga-2hd02v.3.11), rig com `guards=True` (hoje só o WA) roda G12 (daemon agendado pago sem aprovação), G6 (registro MDS), G7 (ntfy direto) e G7b (ação do notify) ANTES do worktree, por wa-remote-guards.py: o código é o de
  `origin/main` do rig e os dados são os OBJETOS do sha, exportados como arquivos inertes (nada do nó é importado nem executado). Reprovou (rc 1 dele COM `RESULT=BLOCKED` do mesmo sha) → recusa 1; não deu para verificar (inclusive um estouro, que também sai 1) → recusa 2; nos dois casos nenhum marcador nasce. As suítes pytest e o resto do hook
  seguem NÃO verificados e o `self_audit:` do marcador diz exatamente isso (só G12, G6, G7 e G7b foram verificados) e conta os AVISO que os guards imprimiram (sem copiar o texto que veio do nó).
  Não roda a checagem "NEW READS NEED A FAILURE TEST" nem a auto-auditoria do diff (são do construtor, antes do push): o marcador registra
  `self_audit: … auto-auditoria do diff NÃO verificada aqui`, visível, não calado.
  Só os rigs da tabela RIGS (gascity, property_scrapers, whatsapp_automation; ga-2hd02v.4): o PAPEL da sessão
  (dog-remote, ps-worker-remote, wa-worker-remote) decide o rig, e com ele a loja da bead, o repositório do worktree e o espelho; o PREFIXO da bead só é CONFERIDO contra o do rig do papel (alias e sessão de
  papéis diferentes, bead de outro prefixo, ou prefixo fora da tabela → recusa; nome de sessão que não é de nenhum papel vale como dog-remote, o comportamento de antes). O marcador do gate mora SEMPRE na loja da cidade; a bead, na do rig. Só reescreve um branch fix/<bead>-… do origin com --force-with-lease e quando
  nada do origin se perde (passo 3b); fora disso o push é o do passo 1 do gate-done.md, que recusa o não-FF.
  Se uma execução morrer no meio (kill do wrapper), sobra o worktree/branch: a próxima recusa e diz o que recolher (nunca apaga o que não criou).

CÓDIGOS DE SAÍDA (o wrapper devolve o do executável; 77 e 124-127 são DELE, e o stderr diz de quem é cada um)
  0 submetido (marcador criado; a linha `bead solta:` ou `AVISO:` diz se a bead foi solta) · 1 recusado ou falhou ANTES do marcador (a bead não mudou; um branch
  fix/… pode ter chegado ao origin) · 2 ambiente ou gate-done.md fora do esperado, ou os guards do WA não puderam ser verificados (nada foi escrito) · 4 o script terminou 0 sem UM marcador identificável (NÃO
  repita às cegas: `bd list -l type:quality-gate-marker -l source-bead:<bead>`).

MODO DE ENSAIO: `GATE_DONE_REMOTE_DRY_RUN=1` resolve tudo (alias, bead, sha, branch, blocos) e imprime o plano; não cria worktree, não empurra, não escreve.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
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
BARE_ROLE_RE = re.compile(r"(?:dog|gate-reviewer|wa-worker|ps-worker|kimi-worker)-remote(?:-adhoc)?")  # nome de sessão SEM cauda: pelo IDENTITY_PATTERN (gc-session-ssh.md) `<papel>-remote-<1-3 dígitos | 3-12 alnum>` TAMBÉM é nome válido de sessão, e `<papel>-remote-adhoc-<10 alnum>` idem (ga-2hd02v.3.13)
SUFFIX_RE = r"-[A-Za-z0-9][A-Za-z0-9._-]{0,40}"  # a cauda de worker/<sessão>-<cauda>: o `-v2`, o `-<bead>`, o `-a2lb9b` que os dogs usam quando worker/<sessão> está preso em outra entrega (ga-2hd02v.3.13)
MIRROR_MAIN = "refs/remotes/origin/main"  # no espelho de produção o main mora SÓ aqui (o hetzner-mirror.sh o sincroniza); não há refs/heads/main
MAX_CANDS = 40  # worker/<sessão>-… acima disso não se confere um a um: recusa e manda usar a forma com argumentos
TIMEOUT_CMD = 120  # um bd/git que pendura não segura a submissão para sempre (o wrapper também corta tudo em timeout_s)
SCRIPT_RAN = [False]  # vira True quando os blocos do gate-done.md começam: daí em diante um erro NÃO é "nada foi escrito" (marcador pode existir)


class Rig(NamedTuple):
    prefix: str    # prefixo do id da bead (ga-…, ps-…): é ele que diz em que loja a bead mora
    name: str      # nome do rig = nome do espelho (<cidade>/.gc/hetzner-mirror/repos/<name>.git) e da pasta do rig
    role: str      # o papel das sessões remotas que submetem DESTE rig (a parte do nome da sessão antes do sufixo)
    routes: tuple  # gc.routed_to de uma volta do gate neste rig: o pool do mini (o que o dispatcher RESTAURA ao reprovar) e o do nó
    prepush: bool = True  # False = o pre-push do rig NÃO roda no mini (ga-2hd02v.3.10): ele executa scripts da ÁRVORE empurrada, e o worktree é sem checkout de propósito (código do nó não roda no mini antes da revisão)
    also: tuple = ()  # outros papéis remotos que submetem DESTE rig (ga-do1ixn.5: kimi-worker-remote no gascity); mesma loja, repositório e espelho do `role`
    guards: bool = False  # True = G12/G6/G7/G7b do pre-push rodam no lugar do hook, pelos OBJETOS do sha e com o código de origin/main (wa-remote-guards.py, ga-2hd02v.3.11); só faz sentido com prepush=False


# ga-2hd02v.4: a tabela do que o atalho atende. Rig fora dela = recusa (nunca "tenta e vê").
RIGS = {
    "ga": Rig("ga", "gascity", "dog-remote", ROUTES, also=("kimi-worker-remote",)),  # kimi-worker-remote: o worker do teste Kimi (ga-do1ixn), 2º papel do HQ
    "ps": Rig("ps", "property_scrapers", "ps-worker-remote", ("ps-worker", "ps-worker-remote")),
    "wa": Rig("wa", "whatsapp_automation", "wa-worker-remote", ("wa-worker", "wa-worker-remote"), prepush=False, guards=True),  # medido 22/10: ~12 dos ~15 guards do pre-push do WA rodam arquivos de $REPO_ROOT (a árvore empurrada); HQ e PS seguem com o hook (PS: só um shim do bd)
}
GUARDS_BIN = Path(__file__).resolve().with_name("wa-remote-guards.py")
GUARDS_TIMEOUT = 180  # medido 23/10 com o mini a load 55: 17 s (WA main, 304 plists) a 65 s; o wrapper corta tudo em timeout_s (300 por padrão), então estourar aqui vira recusa limpa antes de qualquer escrita
GUARDS_PASS_RE = re.compile(r"^wa-remote-guards: RESULT=PASS sha=([0-9a-f]{40}) trusted=([0-9a-f]{40})\s*$", re.M)  # o "certificado": sem esta linha um rc 0 não vale
GUARDS_BLOCK_RE = re.compile(r"^wa-remote-guards: RESULT=BLOCKED sha=([0-9a-f]{40}) trusted=([0-9a-f]{40})\s*$", re.M)  # idem para o rc 1: um Python que estoura também sai 1, e isso NÃO é "reprovou"
GUARDS_WARN_RE = re.compile(r"^wa-remote-guards:\s+AVISO:\s*(.*?)\s*$", re.M)  # uma linha AVISO do exe (G12: plist ilegível / agendado sem entrypoint; G6: fragmento MDS inválido); o grupo é o texto depois de "AVISO:"
ROLE_RE = re.compile(r"(dog-remote|kimi-worker-remote|ps-worker-remote|wa-worker-remote)(?:-|$)")  # o papel de um nome de sessão; gate-reviewer-remote e nomes de teste não casam → vale o rig do HQ, como antes


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


def run(cmd: list, timeout: int = TIMEOUT_CMD, env: dict | None = None) -> subprocess.CompletedProcess:
    """Sem shell. Não levanta: comando que não rodou ou pendurou vira rc 255 com o motivo no stderr (quem chama decide; nunca lido como sucesso vazio). `env` None = o do processo."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
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
    """O branch do espelho que o dog pede para submeter, sem `refs/heads/`. Só vale o que é DESTA sessão (worker/<sessão> ou worker/<sessão>-<cauda>: casamento
    EXATO, nunca prefixo, senão a sessão `x4` passaria por `x`) ou leva o id da bead pedida (fix/<bead> ou fix/<bead>-<resumo>). Qualquer outra coisa → Stop (nada foi lido
    nem escrito). Função pura: a identidade vem do ambiente do atalho (GC_SESSION_NAME), nunca do que o dog escreve."""
    name = raw[len("refs/heads/"):] if raw.startswith("refs/heads/") else raw
    mine = re.fullmatch(rf"worker/{re.escape(sess)}(?:{SUFFIX_RE})?", name)
    fixed = re.fullmatch(rf"fix/{re.escape(bid)}(?:-[A-Za-z0-9._-]{{1,80}})?", name)
    if not (mine or fixed):
        raise Stop(f"{raw[:80]!r} está fora do que esta sessão pode submeter (worker/{sess} ou worker/{sess}-<cauda>, ou fix/{bid} / fix/{bid}-<resumo>)")
    if mine and not fixed and name != f"worker/{sess}" and BARE_ROLE_RE.fullmatch(sess):  # a cauda só é inequívoca se `<sessão>-<cauda>` NÃO for ele mesmo nome de sessão (revisão lateral, ga-2hd02v.1.18)
        raise Stop(f"{name!r}: a sessão {sess!r} não tem cauda, então worker/{sess}-<cauda> pode ser o branch principal de OUTRA sessão ({sess}-N é nome válido): empurre fix/{bid}-<resumo> e submeta esse ref")
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


def my_ref(name: str, sess: str) -> bool:
    """`name` (sem refs/heads/) é um branch principal DESTA sessão: worker/<sessão> exato, ou worker/<sessão>-<cauda> (a cauda só vale se `<sessão>-<cauda>` não puder ser OUTRA sessão: BARE_ROLE_RE)."""
    if name == f"worker/{sess}":
        return True
    return not BARE_ROLE_RE.fullmatch(sess) and re.fullmatch(rf"worker/{re.escape(sess)}{SUFFIX_RE}", name) is not None


def cites(bid: str, text: str) -> bool:
    """O texto cita a bead? Ancorado como o guarda (ga-pj5va): `ga-t5` casa `ga-t5` e `ga-t5.2`, mas não `ga-t50` nem `xga-t5`."""
    return re.search(rf"(?<![A-Za-z0-9]){re.escape(bid)}(?![A-Za-z0-9])", text) is not None


def mirror_main(mirror: str) -> str:
    # vazio (rc 1, sem saída: o espelho não tem refs/remotes/origin/main) → Stop; falhou/ilegível → Stop com o rc: sem o main eu não sei o que já foi entregue, e "tudo é próprio" deixaria passar o commit alheio
    r = run(["git", f"--git-dir={mirror}", "rev-parse", "--verify", "-q", f"{MIRROR_MAIN}^{{commit}}"])
    sha = r.stdout.strip()
    if r.returncode == 1 and not sha:
        raise Stop(f"o espelho não tem {MIRROR_MAIN} (o hetzner-mirror.sh o sincroniza): sem o main não sei quais commits são desta bead; não submeto")
    if r.returncode != 0 or not SHA_RE.fullmatch(sha):
        raise Stop(f"não consegui ler {MIRROR_MAIN} no espelho (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    return sha


def cite_verdict(mirror: str, main: str, sha: str, bid: str) -> tuple:
    """(veredito, n) dos commits PRÓPRIOS de `sha` (os que o main não tem): "no-own" (nenhum: já está no main), "no" (n commits, nenhum cita a bead), "yes".
    vazio (nenhum commit além do main) → "no-own"; falhou (git log) → Stop: nunca vira "sem commits" nem "cita"."""
    r = run(["git", f"--git-dir={mirror}", "log", "-z", "--format=%B", f"{main}..{sha}"])
    if r.returncode != 0:
        raise Stop(f"não consegui ler os commits de {sha[:12]} no espelho (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    msgs = r.stdout.split("\0")
    msgs = msgs[:-1] if msgs[-1] == "" else msgs
    if not msgs:
        return "no-own", 0
    return ("yes" if any(cites(bid, m) for m in msgs) else "no"), len(msgs)


def why_not(verdict: str, n: int, bid: str) -> str:
    return "já está no main (nenhum commit além do main)" if verdict == "no-own" else f"{n} commit(s) próprio(s), nenhum cita {bid}"


def is_ancestor(gitargs: list, a: str, b: str) -> bool:
    # rc 0 → é ancestral; rc 1 → não é; qualquer outro (falhou, objeto ausente) → Stop: "não consegui comparar" nunca vira "não é ancestral"
    r = run(["git"] + gitargs + ["merge-base", "--is-ancestor", a, b])
    if r.returncode not in (0, 1):
        raise Stop(f"não consegui comparar {a[:12]} com {b[:12]} (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    return r.returncode == 0


def commit_time(mirror: str, sha: str) -> int:
    # falhou/ilegível (rc != 0, ou a saída não é um inteiro) → Stop: sem a hora não sei qual dos refs é o mais novo, e "hora 0" faria o ref sem data perder em silêncio
    r = run(["git", f"--git-dir={mirror}", "log", "-1", "--format=%ct", sha])
    if r.returncode != 0 or not re.fullmatch(r"[0-9]{1,12}", r.stdout.strip()):
        raise Stop(f"não consegui ler a hora do commit {sha[:12]} no espelho (git rc={r.returncode}: {(r.stderr.strip() or r.stdout.strip())[:120]})")
    return int(r.stdout.strip())


def utc(ts: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def pick_ref(mirror: str, sess: str, bid: str, rig: str) -> tuple:
    """Sem argumento: de qual worker/<sessão>[-<cauda>] do espelho sai a entrega de `bid`? Só vale o que tem commit PRÓPRIO (que o main não tem) que cita a bead; entre os
    que valem, o que contém os outros. Se nenhum contém os outros (o worker deu amend/rebase e o espelho, que só avança por FF, guardou a versão nova em OUTRO ref: é o caso
    comum), vale o de commit mais novo; empate de hora ou hora ilegível → Stop. Nenhum que sirva → Stop (nunca o ref fixo worker/<sessão> às cegas: ele fica preso na entrega
    anterior). Cada ref que fica de fora é dito, com o motivo. Devolve (ref sem refs/heads/, sha). Nunca olha fix/…: quem quer esse ref usa a forma com argumentos."""
    if not os.path.isdir(mirror):
        raise Stop(f"espelho {mirror} não existe neste mini")
    # for-each-ref e não `git branch --list`: o HEAD do espelho aponta para refs/remotes/origin/main (o main só vive lá), e o `branch` morre com "HEAD not found below refs/heads!"
    # vazio (nenhum worker/<sessão>…) → Stop "o espelho não tem"; falhou/ilegível → Stop: sem a lista não sei o que o servidor empurrou
    r = run(["git", f"--git-dir={mirror}", "for-each-ref", "--format=%(objectname) %(refname)", f"refs/heads/worker/{sess}", f"refs/heads/worker/{sess}-*"])
    if r.returncode != 0:
        raise Stop(f"não consegui ler worker/{sess}… no espelho (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    cands = []
    for ln in r.stdout.splitlines():
        m = re.fullmatch(r"([0-9a-f]{40}) refs/heads/(\S+)", ln)
        if not m:
            raise Stop(f"a lista de worker/{sess}… do espelho veio ilegível ({ln[:80]!r})")
        if my_ref(m.group(2), sess):
            cands.append((m.group(2), m.group(1)))
    if not cands:
        raise Stop(f"o espelho não tem worker/{sess}: o `git push origin HEAD:refs/heads/worker/{sess}` do servidor não chegou (ou a sessão é de outro rig; este espelho é o do {rig})")
    if len(cands) > MAX_CANDS:
        raise Stop(f"{len(cands)} refs worker/{sess}… no espelho (mais que {MAX_CANDS}): não confiro um a um; use `gate-done {bid} <ref> <sha>`")
    main = mirror_main(mirror)
    kept, why = [], []
    for ref, sha in sorted(cands):
        verdict, n = cite_verdict(mirror, main, sha, bid)
        if verdict == "yes":
            kept.append((ref, sha))
        else:
            why.append(f"{ref} {why_not(verdict, n, bid)}")
            say(f"ignorei {ref} ({why_not(verdict, n, bid)})")
    if not kept:
        raise Stop(f"nenhum worker/{sess}… do espelho serve para {bid}: {'; '.join(why)}. Empurre o commit da bead (que cite {bid}) e repita")
    gd = [f"--git-dir={mirror}"]
    tip = kept[0]
    for c in kept[1:]:  # o candidato a "mais novo": passa para c quando o atual é ancestral dele; a conferência abaixo diz se de fato é o topo
        if is_ancestor(gd, tip[1], c[1]):
            tip = c
    if not all(is_ancestor(gd, c[1], tip[1]) for c in kept if c is not tip):
        # nenhum contém os outros: vale o commit mais novo (a hora do COMMIT: amend e rebase a renovam); empate entre os dois mais novos → Stop, não chuto
        stamped = sorted(((commit_time(mirror, c[1]), c) for c in kept), key=lambda x: x[0], reverse=True)
        if stamped[0][0] == stamped[1][0]:
            raise Stop(f"{len(kept)} refs do espelho citam {bid} e divergem ({', '.join(x[0] for x in kept)}), e os dois mais novos ({stamped[0][1][0]}, {stamped[1][1][0]}) têm a mesma hora de commit ({utc(stamped[0][0])}): "
                       f"não escolho. Diga qual: `gate-done {bid} <ref> <sha>`")
        tip = stamped[0][1]
    for c in kept:
        if c is tip:
            continue
        if is_ancestor(gd, c[1], tip[1]):
            say(f"ignorei {c[0]} (é ancestral de {tip[0]}: o commit mais novo da bead já o contém)")
        else:
            say(f"ignorei {c[0]} (diverge de {tip[0]}, que tem o commit mais novo: {utc(commit_time(mirror, tip[1]))} contra {utc(commit_time(mirror, c[1]))}; se o certo era esse: `gate-done {bid} {c[0]} {c[1]}`)")
    return tip


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


def origin_tip(wt: str, env: dict, branch: str) -> str:
    # vazio (o origin não tem o branch) → "": o push do gate-done.md o cria; falhou/ilegível → Stop: "não consegui ler" nunca vira "não tem" (empurrar às cegas por cima do que talvez exista)
    r = run(["git", "-C", wt, "ls-remote", "--heads", "origin", f"refs/heads/{branch}"], env=env)
    if r.returncode != 0:
        raise Stop(f"não consegui ler {branch} no origin (git rc={r.returncode}: {r.stderr.strip()[:120]})")
    out = r.stdout.strip()
    if not out:
        return ""
    m = re.fullmatch(rf"([0-9a-f]{{40}})\trefs/heads/{re.escape(branch)}", out)
    if not m:
        raise Stop(f"{branch} no origin: a resposta do ls-remote veio ilegível ({out[:80]!r})")
    return m.group(1)


def lease_push(repo: str, wt: str, env: dict, sess: str, branch: str, sha: str, tmp: list) -> None:
    """O origin já tem `branch` e o novo `sha` não o contém (o dispatcher REBASEOU o fix/<bead>-… sobre o main novo, ou alguém empurrou algo): o `git push origin HEAD` do passo 1 do gate-done.md
    seria recusado (não-FF; wa-xr1xwt). Aqui: se NADA se perde (todo commit do origin, fora o que já está no main, existe em `sha` como o mesmo commit ou como patch equivalente),
    empurra com --force-with-lease=<ref>:<o que li>, que o origin recusa se mudou depois da leitura; senão recusa com o que fazer. Sem branch no origin, igual ao sha, ou ancestral do sha
    (FF) → não faz nada: o passo 1 empurra como sempre. As refs temporárias que a busca cria entram em `tmp` (o `finally` do submit as recolhe). Nada foi escrito se levantar Stop."""
    tip = origin_tip(wt, env, branch)
    if not tip or tip == sha:
        return
    t_ref, m_ref = f"refs/gt-remote/{sess}.origin", f"refs/gt-remote/{sess}.main"
    tmp += [t_ref, m_ref]
    r = run(["git", "-C", repo, "fetch", "-q", "--no-tags", "--no-write-fetch-head", "origin", f"+refs/heads/{branch}:{t_ref}", f"+refs/heads/main:{m_ref}"], timeout=240, env=env)
    if r.returncode != 0:
        raise Stop(f"não consegui buscar {branch} do origin (git rc={r.returncode}: {r.stderr.strip()[:160]})")
    if is_ancestor(["-C", wt], tip, sha):
        return
    # vazio (nada no origin que `sha` não tenha) → empurra com lease; tem commit → Stop "refaça"; falhou (objeto ausente, git que não leu) → Stop: "não consegui conferir" nunca vira "nada a perder"
    lost = run(["git", "-C", wt, "rev-list", "--right-only", "--cherry-pick", f"{sha}...{tip}", f"^{m_ref}"])
    if lost.returncode != 0:
        raise Stop(f"não consegui conferir se o origin tem algo que {sha[:12]} não tem (git rc={lost.returncode}: {lost.stderr.strip()[:120]}): não reescrevo {branch}")
    extra = lost.stdout.split()
    if extra:
        raise Stop(f"o origin tem {len(extra)} commit(s) em {branch} (a ponta é {tip[:12]}, ex.: {extra[0][:12]}) que {sha[:12]} não tem, nem como patch equivalente, e que o main também não tem: empurrar os perderia. "
                   f"Refaça o commit em cima do que o origin tem (git fetch origin; git rebase origin/{branch}), empurre ao servidor e rode de novo. Nada foi escrito")
    say(f"AVISO: {branch} no origin está em {tip[:12]}, que não é ancestral de {sha[:12]} (o dispatcher reescreveu o fix/?), mas tudo o que ele tem já está no main ou aqui como patch equivalente: "
        f"empurro com --force-with-lease={branch}:{tip[:12]} (o origin recusa se mudou depois da minha leitura)")
    p = run(["git", "-C", wt, "push", f"--force-with-lease=refs/heads/{branch}:{tip}", "origin", f"{sha}:refs/heads/{branch}"], timeout=240, env=env)
    if p.returncode != 0:
        raise Stop(f"o push com --force-with-lease de {branch} (esperando {tip[:12]} no origin) falhou: o origin mudou depois que li, ou o hook do push recusou (git rc={p.returncode}: {p.stderr.strip()[:200]}). Nada foi submetido")


def guards_avisos(out: str) -> str:
    """O que o marcador (self_audit:) diz dos AVISO que os guards imprimiram: não bloqueiam (o hook também deixaria passar), mas o revisor do gate os lê onde decide, não só no stderr do cliente
    (um plist agendado sem entrypoint resolvido foi o único rastro de um buraco medido no gate 1 da ga-2hd02v.3.11). Só entra a parte escrita pelo wa-remote-guards.py, até o 1º "): " de cada linha: o que
    vem depois (Label de plist, nome de arquivo, motivo) é texto do NÓ, e o revisor lê este campo como fato, então ele nunca é copiado. Linha de forma que não reconheço entra contada e sem o texto."""
    # vazio (nenhuma linha AVISO) → "nenhum AVISO": quem chama só chega aqui com o certificado conferido, então o exe foi até o fim e a ausência é resposta; ilegível (linha sem "): ") → conta e diz "forma desconhecida", nunca copia
    linhas = GUARDS_WARN_RE.findall(out)
    if not linhas:
        return "nenhum AVISO dos guards"
    shown = []
    for ln in linhas[:4]:
        head, sep, _ = ln.partition("): ")
        shown.append(unicodedata.normalize("NFKD", head + ")").encode("ascii", "ignore").decode()[:160] if sep else "forma desconhecida (texto nao copiado)")
    return (f"{len(linhas)} AVISO(s) dos guards (nao bloqueiam; o hook tambem deixaria passar; confira no diff): " + " | ".join(shown)
            + (f" | (+{len(linhas) - 4} nao listado(s))" if len(linhas) > 4 else ""))


def wa_guards(ctx: Ctx, sha: str, work: Path) -> str:
    """Roda G12/G6/G7/G7b sobre os OBJETOS de `sha` (wa-remote-guards.py, em subprocesso: código de confiança de origin/main do rig, dados inertes do sha). Devolve a nota do self_audit.
    Reprovou (rc 1 dele COM `RESULT=BLOCKED sha=<este sha>`) → Stop rc 1; não deu para saber (rc 2, timeout, estouro que também sai 1, saída sem o certificado, qualquer outra coisa) → Stop rc 2. Nunca chega ao marcador sem o certificado `RESULT=PASS sha=<este sha>`."""
    scratch = tempfile.mkdtemp(prefix="guards-", dir=work)  # falhou (disco, permissão) → OSError sobe como erro interno antes do script: nada foi escrito
    try:
        # vazio (sem saída) → sem certificado → Stop rc 2; falhou/ilegível (rc != 0, timeout 255, sem a linha RESULT, sha diferente) → Stop; nunca "passou"
        r = run([sys.executable, "-I", "-B", str(GUARDS_BIN), "--repo", ctx.repo, "--sha", sha, "--scratch", scratch], timeout=GUARDS_TIMEOUT)
        for ln in r.stdout.splitlines():
            say(ln[len("wa-remote-guards: "):] if ln.startswith("wa-remote-guards: ") else ln)
        blocked = GUARDS_BLOCK_RE.findall(r.stdout)
        if r.returncode == 1 and len(blocked) == 1 and blocked[0][0] == sha:
            raise Stop(f"os guards G12/G6/G7/G7b do pre-push de {ctx.rig.name} reprovaram {sha[:12]} (linhas BLOQUEADO acima): corrija no branch, empurre e submeta de novo. Nenhum marcador foi criado", 1)
        found = GUARDS_PASS_RE.findall(r.stdout)
        if r.returncode != 0 or len(found) != 1 or found[0][0] != sha:
            raise Stop(f"não consegui verificar G12/G6/G7/G7b em {sha[:12]} (wa-remote-guards.py rc={r.returncode}, {len(found)} certificado(s); stderr: {r.stderr.strip()[:160]!r}): "
                       f"não submeto sem saber. O problema está no mini, não no seu diff: avise o Mayor", 2)
        return (f"so G12, G6, G7 e G7b foram verificados (pelos OBJETOS de {sha[:12]}, com os guards de origin/main @ {found[0][1][:12]}, wa-remote-guards.py); "
                f"os demais guards do pre-push e as suites pytest nao foram verificados; " + guards_avisos(r.stdout))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
        if os.path.exists(scratch):
            say(f"AVISO: não recolhi a pasta temporária dos guards {scratch}")


def submit(city: str, ctx: Ctx, alias: str, sess: str, bid: str, sha: str, src: str, branch: str, script: str) -> int:
    repo, mirror = ctx.repo, ctx.mirror
    work = Path(city) / ".gc" / "gate-done-remote"    # a trava mora na cidade; o worktree, sob o caminho do rig (HQ: a mesma pasta de antes)
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(work / f"{bid}.lock", "a")
    wtd = Path(ctx.wt_base)
    wtd.mkdir(parents=True, exist_ok=True, mode=0o700)
    wt, ref = str(wtd / f"wt-{bid}"), f"refs/gt-remote/{sess}"
    made_wt = made_ref = False
    tmp_refs: list = []  # as refs temporárias que a busca no origin cria (lease_push); recolhidas no finally
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
        guards_note = wa_guards(ctx, sha, work) if ctx.rig.guards else ""  # depois do fetch (os objetos já estão em `repo`) e ANTES de criar o worktree: reprovou → nada além da ref temporária, que o finally recolhe
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
            env["SELF_AUDIT_SUMMARY"] += f"; ATENCAO: o pre-push de {ctx.rig.name} NAO rodou no mini (executaria codigo do no antes da revisao): " + (guards_note or "os guards dele nao foram verificados")
            say(f"AVISO: o pre-push de {ctx.rig.name} NÃO roda no mini (ele executaria scripts da árvore do nó antes da revisão); o marcador registra isso em self_audit"
                + ("; G12, G6, G7 e G7b passaram pelos objetos do sha, o resto do hook (suítes pytest incluídas) NÃO foi verificado" if guards_note else ""))
        lease_push(repo, wt, env, sess, branch, sha, tmp_refs)  # antes de qualquer escrita no banco: o origin com o fix/ reescrito não derruba o passo 1 do gate-done.md
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
            + ([["git", "-C", repo, "update-ref", "-d", ref]] if made_ref else []) \
            + [["git", "-C", repo, "update-ref", "-d", t] for t in tmp_refs]
        for cmd in steps:
            r = run(cmd)
            if r.returncode != 0:
                say(f"AVISO: não recolhi ({' '.join(cmd[3:6])}): {r.stderr.strip()[:120]}")
        lock.close()


def rig_of_session(sess: str) -> str:
    """O prefixo do rig de uma sessão pelo PAPEL no nome (dog-remote-…, ps-worker-remote-…, wa-worker-remote-…). Papel que não casa (gate-reviewer-remote, nome de teste) → "ga": o HQ, como antes da tabela."""
    m = ROLE_RE.match(sess)
    return next((p for p, r in RIGS.items() if m and m.group(1) in (r.role,) + r.also), "ga")


def role_of(name: str) -> str:
    """O papel remoto no nome (alias ou sessão), ou "" quando não há (gate-reviewer-remote, nome de teste). Dois papéis do MESMO rig (dog-remote e kimi-worker-remote no gascity) são papéis diferentes."""
    m = ROLE_RE.match(name)
    return m.group(1) if m else ""


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
    # o identity_pattern do atalho é GLOBAL (casa todos os papéis), então alias de um papel com sessão de outro passa por ele: aqui o alias e a sessão têm de ser do MESMO papel, e não só do mesmo
    # rig quando os DOIS nomes têm papel (ga-do1ixn.5: dog-remote e kimi-worker-remote são os dois do gascity; o mesmo rig não basta). Nome sem papel (remote-e2e-1, gate-reviewer-remote) vale como
    # o HQ e só conta pelo rig, como antes
    ra, rs = role_of(alias), role_of(sess)
    if rig_of_session(alias) != role_prefix or (ra and rs and ra != rs):
        raise Stop(f"identidade mista: o alias {alias!r} é do papel {role_of(alias) or '(nenhum)'} (rig {RIGS[rig_of_session(alias)].name}) e a sessão {sess!r} é do papel {role_of(sess) or '(nenhum)'} "
                   f"(rig {RIGS[role_prefix].name}): não submeto", 2)
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
    bid = bead["id"]
    if bid.split("-", 1)[0] != role_prefix:  # a lista da loja do rig só devolve bead dele; se não for, algo está errado e eu não submeto
        raise Stop(f"a bead {bid} não é do rig {ctx.rig.name} (prefixo {role_prefix}): não submeto")
    if want is None:  # sem argumento: o ref é o que tem commit PRÓPRIO que cita a bead (worker/<sessão> fica preso na entrega anterior; ga-2hd02v.3.13)
        src, sha = pick_ref(ctx.mirror, sess, bid, ctx.rig.name)
    else:
        sha = mirror_sha(ctx.mirror, src, ctx.rig.name)
        if sha != want:  # antes do marcador: o gate nunca recebe um sha que o dog não disse
            raise Stop(f"o espelho tem {sha[:12]} em {src}, mas você disse {want[:12]}: o push não chegou ou veio depois; empurre de novo (git push origin HEAD:refs/heads/{src}) e repita. Nada foi submetido")
        verdict, n = cite_verdict(ctx.mirror, mirror_main(ctx.mirror), sha, bid)  # a regra do guarda (ga-pj5va): o commit entregue cita a bead; nunca o sha de outra bead
        if verdict != "yes":
            raise Stop(f"{src}@{sha[:12]}: {why_not(verdict, n, bid)}: não submeto o commit de outra bead (ou já entregue). Empurre o commit desta bead, que cite {bid}, e repita")
    branch = src if src.startswith("fix/") else f"fix/{bid}-{slugify(bead.get('title', ''))}"  # o nome no origin SEMPRE leva o id da bead (o gate o extrai dele); worker/… não leva
    if run(["git", "check-ref-format", "--branch", branch]).returncode != 0:
        raise Stop(f"{branch!r} não é um nome de branch válido")
    script = gate_done_script(Path(city) / "commands" / "gate-done.md")
    print(f"gate-done-remote: alias={alias} sessão={sess} bead={bid} {src}@{sha[:12]} → {branch}", flush=True)
    if os.environ.get("GATE_DONE_REMOTE_DRY_RUN") == "1":
        print(f"ensaio: nada foi escrito (blocos do gate-done.md: {len(script.splitlines())} linhas)", flush=True)
        if ctx.rig.guards:
            print(f"ensaio: no envio de verdade G12/G6/G7/G7b de {ctx.rig.name} rodam antes do worktree, pelos objetos de {sha[:12]} (wa-remote-guards.py); o ensaio não os roda", flush=True)
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
