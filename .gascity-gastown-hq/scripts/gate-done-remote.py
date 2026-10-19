#!/usr/bin/env python3
"""gate-done-remote.py — o executável que o `gate-done` de uma sessão do servidor Hetzner roda NO MINI (ga-2hd02v.1.13).

Contents
  O que é · O que faz, em ordem · O que não faz · Códigos de saída · Modo de ensaio

O QUE É
  É o `gate_done_bin` do remote-shim-wrapper.py: o wrapper o executa quando a sessão remota roda `gate-done` (a regra da lista é a forma exata,
  sem argumento), com a cidade como cwd e o ambiente montado do zero (BEADS_ACTOR = alias, mais a identidade que o servidor declarou e que casou
  com o identity_pattern). Antes dele o wrapper recusava (rc 77, "gate_done_bin ausente") e o Mayor submetia à mão.

O QUE FAZ, EM ORDEM (passo que não consegue saber algo para sem escrever nada: "não sei" nunca vira "pode")
  1. Quem pede: alias = BEADS_ACTOR, sessão = GC_SESSION_NAME. Os dois precisam ter o formato esperado.
  2. A bead: a ÚNICA bead in_progress atribuída ao alias na cidade. Nenhuma, ou mais de uma → recusa (nunca adivinha qual submeter).
  3. O trabalho: a ponta de `worker/<sessão>` no espelho (<cidade>/.gc/hetzner-mirror/repos/gascity.git), onde o `git push` do servidor chegou.
     O nome `worker/<sessão>` não leva o id da bead e o gate extrai o id do nome do branch; por isso a submissão sai de um branch
     `fix/<bead>-<resumo>` no MESMO sha, criado num worktree descartável do mini (sem checkout: o gate-done só lê objetos).
  4. A submissão É o /gate-done: os blocos bash dos passos 1 a 4 de commands/gate-done.md são lidos DAQUI, a cada execução, e rodados juntos no worktree
     (push do branch, bead e rig, marcador, gate:queued, gate.submitted_by). Não há cópia deles neste arquivo: mudar o gate-done.md muda isto também.
     Se o arquivo mudar de forma (não achar exatamente um bloco bash por passo), nada é empurrado.
  5. Só depois do marcador, e só se `gate.submitted_by` aparece nele: solta a bead (tira `gc.routed_to`, depois o assignee, que só sai se ainda for o
     alias). Sem isso o pool do dog-remote recria uma sessão fresca a cada idle_timeout (15 min) enquanto a bead seguir atribuída ao alias (achado do
     dog-4 em ga-2hd02v.1.6). O guarda do gate faz o mesmo ao claimar; aqui é antes, para a janela não existir.
  6. Recolhe o que esta execução criou (worktree, branch local, ref temporária) e imprime o sha submetido. Nenhum git daqui dispara gc/manutenção.

O QUE NÃO FAZ
  Não vê o HEAD do servidor: submete o que o ESPELHO tem em worker/<sessão> e imprime esse sha. Quem rodou o `gate-done` compara com `git rev-parse HEAD`
  (se diferir, o `git push origin HEAD` não chegou ou veio depois: empurre e rode de novo; o gate junta marcadores do mesmo branch).
  Não roda a checagem "NEW READS NEED A FAILURE TEST" nem a auto-auditoria do diff (são do construtor, antes do push): o marcador registra
  `self_audit: … auto-auditoria do diff NÃO verificada aqui`, visível, não calado.
  Só o rig `gascity` (o único com worktree no servidor hoje); bead de outro rig não é suportada. Não força push: um branch fix/<bead>-… que já está no
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

RIG = "gascity"  # o único rig com worktree no servidor (agents/dog-remote/agent.toml: worktree_rigs)
ALIAS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SESS_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,60}")  # o formato que o `wt-add` aceita: é dele que vem o nome do branch worker/<sessão>
BEAD_RE = re.compile(r"[a-z]{2,8}-[a-z0-9]{2,16}(?:\.[0-9]{1,4}){0,3}")  # o id que o passo 2 do gate-done.md extrai do nome do branch (se divergirem, ELE recusa)
MARKER_RE = re.compile(r"^Marker created: (\S+)\s*$", re.M)
TIMEOUT_CMD = 120  # um bd/git que pendura não segura a submissão para sempre (o wrapper também corta tudo em timeout_s)
SCRIPT_RAN = [False]  # vira True quando os blocos do gate-done.md começam: daí em diante um erro NÃO é "nada foi escrito" (marcador pode existir)


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
    # vazio ([]) → Stop "nenhuma bead"; falhou/ilegível → Stop do bd_json; duas ou mais → Stop: a submissão nunca escolhe
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


def mirror_sha(mirror: str, sess: str) -> str:
    # vazio (a ref não existe, rc 1) → Stop "o push não chegou"; falhou/ilegível (espelho ausente, git que não leu) → Stop com o rc
    if not os.path.isdir(mirror):
        raise Stop(f"espelho {mirror} não existe neste mini")
    r = run(["git", f"--git-dir={mirror}", "rev-parse", "--verify", "-q", f"refs/heads/worker/{sess}^{{commit}}"])
    sha = r.stdout.strip()
    if r.returncode == 1 and not sha:
        raise Stop(f"o espelho não tem worker/{sess}: o `git push origin HEAD` do servidor não chegou (ou a sessão é de outro rig; só {RIG})")
    if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise Stop(f"não consegui ler worker/{sess} no espelho (git rc={r.returncode}: {r.stderr.strip()[:120]})")
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


def release(city: str, bead: str, alias: str, marker: str) -> None:
    """Solta a bead do pool DEPOIS do marcador. Leitura que falha ou vem sem gate.submitted_by → não solta e diz (o guarda do gate a solta ao claimar)."""
    try:
        # vazio (sem gate.submitted_by) → não solta; falhou/ilegível → não solta
        who = ((first(bd_json(city, ["show", marker, "--json"], f"o marcador {marker}")) or {}).get("metadata") or {}).get("gate.submitted_by")
    except (Stop, AttributeError, TypeError) as e:
        print(f"AVISO: não soltei {bead}: não consegui ler o marcador {marker} ({e}); o guarda do gate a solta ao claimar", flush=True)
        return
    if not who:
        print(f"AVISO: não soltei {bead}: {marker} não tem gate.submitted_by (soltar agora faria o guarda atribuir o autor ao criador da bead); o guarda do gate a solta ao claimar", flush=True)
        return
    a = run(["bd", "-C", city, "update", bead, "--unset-metadata", "gc.routed_to", "-q"])  # a rota primeiro: sem ela nenhuma sonda de pool reclama a bead
    b = run(["bd", "-C", city, "update", bead, "--if-assignee", alias, "-a", "", "-q"])  # só sai se AINDA for o alias: outro dono não é tirado
    try:
        # confere o EFEITO, não o rc: vazio → solta; falhou/ilegível → "?" = não sei, dito como aviso
        now = first(bd_json(city, ["show", bead, "--json"], f"a bead {bead}")) or {}
        left = [k for k, v in (("assignee", now.get("assignee")), ("gc.routed_to", (now.get("metadata") or {}).get("gc.routed_to"))) if v]
    except (Stop, AttributeError, TypeError):
        left = ["?"]
    if left:
        print(f"AVISO: {bead} NÃO ficou solta (resta {', '.join(left)}; unset rc={a.returncode}, assignee rc={b.returncode}); o guarda do gate a solta ao claimar", flush=True)
    else:
        print(f"bead solta: {bead} sem assignee e sem gc.routed_to", flush=True)


def submit(city: str, repo: str, alias: str, sess: str, bid: str, sha: str, mirror: str, branch: str, script: str) -> int:
    work = Path(city) / ".gc" / "gate-done-remote"
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(work / f"{bid}.lock", "a")
    wt, ref = str(work / f"wt-{bid}"), f"refs/gt-remote/{sess}"
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
        r = run(["git", "-C", repo, "fetch", "-q", "--no-tags", "--no-write-fetch-head", mirror, f"+refs/heads/worker/{sess}:{ref}"], timeout=240)
        if r.returncode != 0:
            raise Stop(f"não consegui buscar worker/{sess} do espelho (git rc={r.returncode}: {r.stderr.strip()[:160]})")
        r = run(["git", "-C", repo, "worktree", "add", "-q", "--no-checkout", "-b", branch, wt, sha], timeout=240)
        if r.returncode != 0:
            raise Stop(f"não consegui criar o worktree de {branch} em {sha[:12]} (git rc={r.returncode}: {r.stderr.strip()[:160]})")
        made_wt = True
        head = run(["git", "-C", wt, "rev-parse", "HEAD"]).stdout.strip()
        if head != sha:  # o que vai ao gate tem de ser exatamente o que o espelho tinha
            raise Stop(f"o worktree ficou em {head[:12]!r}, não em {sha[:12]}")
        env = {**os.environ, "GC_CITY_PATH": city, "GC_ALIAS": os.environ.get("GC_ALIAS", alias), "GIT_TERMINAL_PROMPT": "0",
               "SELF_AUDIT_SUMMARY": f"submetido pelo atalho remoto (gate-done-remote.py) em nome de {alias}, sessão {sess}, sha {sha[:12]}; auto-auditoria do diff NAO verificada aqui"}
        SCRIPT_RAN[0] = True
        p = subprocess.run(["bash", "-c", script], cwd=wt, env=env, stdout=subprocess.PIPE, text=True, errors="replace")  # o stderr do script segue direto ao cliente
        print(p.stdout, end="", flush=True)
        if p.returncode != 0:
            raise Stop(f"os blocos do gate-done.md saíram {p.returncode}: nenhum marcador criado; veja as linhas acima")
        found = MARKER_RE.findall(p.stdout)
        if len(found) != 1:
            say(f"ATENÇÃO: o script saiu 0 mas vi {len(found)} linha(s) 'Marker created': NÃO repita às cegas, confira os marcadores de {bid}")
            return 4
        release(city, bid, alias, found[0])
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


def main() -> int:
    city = os.path.realpath(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    if os.path.realpath(os.getcwd()) != city:  # o wrapper roda com cwd = cidade; outro cwd é uso fora do desenho
        raise Stop(f"cwd {os.getcwd()} não é a cidade {city}: este executável é chamado pelo remote-shim-wrapper (ensaio: cd na cidade)", 2)
    alias, sess = os.environ.get("BEADS_ACTOR", ""), os.environ.get("GC_SESSION_NAME", "")
    if not ALIAS_RE.fullmatch(alias) or not SESS_RE.fullmatch(sess):
        raise Stop(f"BEADS_ACTOR={alias[:40]!r} / GC_SESSION_NAME={sess[:40]!r} fora do formato: sem saber quem pede não submeto", 2)
    # nenhum git desta submissão (nem os do gate-done.md) dispara gc/manutenção no repositório compartilhado: o disco do mini vive no piso do heavy-guard (ga-vln2py)
    os.environ.update({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0", "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false"})
    mirror = os.environ.get("GATE_DONE_REMOTE_MIRROR") or f"{city}/.gc/hetzner-mirror/repos/{RIG}.git"
    bead = one_bead(city, alias)
    bid = bead["id"]
    sha = mirror_sha(mirror, sess)
    branch = f"fix/{bid}-{slugify(bead.get('title', ''))}"
    if run(["git", "check-ref-format", "--branch", branch]).returncode != 0:
        raise Stop(f"{branch!r} não é um nome de branch válido")
    script = gate_done_script(Path(city) / "commands" / "gate-done.md")
    # vazio/falhou (git não achou o repositório) → Stop: sem repositório não há onde criar o worktree
    top = run(["git", "-C", city, "rev-parse", "--show-toplevel"])
    if top.returncode != 0 or not top.stdout.strip():
        raise Stop(f"não achei o repositório da cidade (git rc={top.returncode}: {top.stderr.strip()[:100]})")
    print(f"gate-done-remote: alias={alias} sessão={sess} bead={bid} worker/{sess}@{sha[:12]} → {branch}", flush=True)
    if os.environ.get("GATE_DONE_REMOTE_DRY_RUN") == "1":
        print(f"ensaio: nada foi escrito (blocos do gate-done.md: {len(script.splitlines())} linhas)", flush=True)
        return 0
    return submit(city, top.stdout.strip(), alias, sess, bid, sha, mirror, branch, script)


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
