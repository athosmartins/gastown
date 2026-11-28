#!/usr/bin/env python3
"""agent-battery-corpus.py — monta o acervo de tarefas da bateria noturna de agentes (ga-hyp55ss, fatia 1).

## Contents
  Uso · O que entra · O que NÃO entra · Saída · Códigos de saída

USO: agent-battery-corpus.py [--repo DIR] [--ref REF] [--prefix SUBPASTA] [--days N] [--n N] [--min N]
        [--salt S] [--oversample K] [--bd CMD] [--out ARQ] [--dry-run]
  Lê o histórico git já MERGEADO (o que o gate empurrou para a main) e devolve até --n tarefas (padrão 40) em JSONL.
  Cada tarefa = uma bead fechada cuja entrega mexeu em código de produção E trouxe um `*.selftest.sh`: o critério de
  sucesso é verificável por máquina (o selftest da entrega REPROVA em base_sha e PASSA com o patch certo). Esta fatia só
  MONTA o acervo; quem confere "reprova na base / passa no fix" e roda o agente é a fatia 2 (scripts/agent-battery-run.py; o
  desenho da série está em docs/runbooks/agent-battery.md).

O QUE ENTRA (todas as condições): bead `ga-*` citada no escopo do assunto do commit (`fix(ga-x): …`); dentro dos --days
  (padrão 60); pelo menos 1 `*.selftest.sh` e 1 arquivo de produção (scripts/, packs/, formulas/, commands/); no máximo 4 commits,
  6 arquivos de produção, 3 selftests e 300 linhas de produção; nenhum commit de outra bead mexeu nos mesmos arquivos entre o
  primeiro e o último commit da bead (senão base→fix não isola a entrega); bead legível, fechada, com enunciado.
O QUE NÃO ENTRA: arquivo fora da allowlist (city.toml, agents/, .beads, .gc, dados), binário, bead reaberta, `revert` (o do git,
  `Revert "…"`, e o convencional) e dado pessoal: telefone, CPF, e-mail ou qualquer sequência de 10 a 13 dígitos no título, no
  enunciado ou no assunto dos commits da bead. É heurística de FORMA, não garantia (não pega nome, endereço, número solto de 8-9
  dígitos nem número colado a letra); um acerto basta, ao contrário do hetzner-pii-scan.py, que caça LISTA. Cada exclusão é CONTADA
  por motivo na saída; nada some em silêncio. Arquivo apagado ou renomeado pela bead continua na lista (renomear = apagar + criar): o
  executor confere os SELFTESTS em fix_sha e descarta a tarefa com motivo (selftest_ausente_no_fix); prod_files só informa.
SAÍDA: JSONL em --out (padrão $GC_CITY_PATH/.gc/agent-battery/tasks.jsonl, fora do git) + <out>.meta.json (sha256 do JSONL,
  parâmetros, contagens, sha da ponta lida) + <out>.lock (trava, vazia). `role` = papel de quem construiu a bead (dog, wa-worker,
  ps-worker, outro, sem-papel), de gc.session_name: a bead fechada perde o assignee e quase sempre o gc.routed_to. Resumo JSON no stdout.
  PUBLICAÇÃO do par: prepara os DOIS temporários, guarda o acervo antigo, troca o acervo e por ÚLTIMO o meta; se o meta não troca, o
  acervo antigo volta e nenhum .tmp-corpus-* fica. Duas rodadas ao mesmo tempo: a 2ª espera a trava por até 30 s.
CÓDIGOS: 0 ok · 2 uso errado (inclui --bd vazio ou com aspas desbalanceadas) ou git ilegível (nada escrito) · 3 menos tarefas que
  --min (nada escrito, o acervo antigo fica) · 4 não consegui gravar (o par anterior continua; só a FALHA DUPLA, meta que não troca E
  acervo antigo que não volta, deixa par torto: a mensagem diz PAR TORTO e onde o antigo ficou) · 5 `bd` não respondeu em metade ou
  mais das leituras (não sei dizer se o filtro é rígido: nada escrito).
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

BEAD = r"\((ga-[a-z0-9]+(?:\.[0-9]{1,4})*)\)"
BEAD_RE = re.compile(r"^[a-z]+" + BEAD)
REVERT_RE = re.compile(r'^Revert "[a-z]+' + BEAD)  # o assunto padrão do `git revert`: Revert "fix(ga-x): …"
ALLOW_ROOTS = ("scripts/", "packs/", "formulas/", "commands/", "docs/")
PROD_ROOTS = ("scripts/", "packs/", "formulas/", "commands/")


def _num(p):  # número só como palavra inteira: a guarda alfanumérica evita casar dentro de sha/hex/ids
    return r"(?<![0-9A-Za-z])" + p + r"(?![0-9A-Za-z])"


# Um acerto basta para tirar a tarefa (dado de lead não vai para o nó). É heurística de FORMA, não garantia: não pega nome, endereço,
# número solto de 8-9 dígitos nem número colado a letra (`fone31987654321`, o preço da guarda). Em troca exclui a mais: uma faixa 4+4
# (1000-1010, 8095-8097) lê-se como telefone.
PII_RE = re.compile("|".join([
    _num(r"[0-9]{10,13}"),                                          # CPF sem pontos, telefone com/sem DDD e 55, id de chat
    _num(r"\+?(?:55 ?)?\(?[1-9][0-9]\)? ?9?[0-9]{4}[- ]?[0-9]{4}"),  # telefone com DDD: (31) 98765-4321, 31 98765 4321, +55 31 …
    _num(r"9?[0-9]{4}-[0-9]{4}"),                                    # telefone sem DDD, com hífen
    _num(r"[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}"),                  # CPF pontuado
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",              # e-mail (também 5531…@s.whatsapp.net)
]))
ROLE_RE = re.compile(r"(?<![a-z0-9])(wa-worker|ps-worker|dog)(?![a-z0-9])")  # fronteira: hotdog-x não é dog
LIMITS = {"commits": 4, "prod_files": 6, "test_files": 3, "prod_lines": 300}
LOCK_WAIT_S = 30  # quanto esperar outra rodada que está gravando (a gravação leva milissegundos)


def die(code, msg):
    print("agent-battery-corpus: " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, timeout):
    """(rc, stdout) — rc None = não rodou (binário ausente) ou estourou o prazo: 'não consegui saber', nunca vazio.
    A saída é lida SEMPRE como UTF-8 (byte inválido vira U+FFFD): o locale de quem roda não muda o acervo."""
    try:
        p = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout


def read_log(repo, ref, prefix, days):
    # vazio → devolve [] e o chamador sai com rc 3 (nada a escolher); falhou/ilegível → die(2), nada é escrito.
    since = "--since=%d days ago" % days
    # --no-renames: sem ele o git escreve `scripts/{a => b}` e o executor descarta a tarefa inteira (caminho fora da regex dele)
    rc, out = run(["git", "-C", repo, "log", ref, since, "--no-merges", "--no-renames", "--numstat",
                   "--format=@@%H%x1f%P%x1f%s", "--", prefix], 180)
    if rc != 0:
        die(2, "git log falhou em %s (ref %s, rc=%s)" % (repo, ref, rc))
    commits, cur = [], None
    for line in out.splitlines():
        if line.startswith("@@"):
            sha, parents, subj = (line[2:].split("\x1f") + ["", ""])[:3]
            cur = {"sha": sha, "parent": parents.split(" ")[0] if parents else "", "subject": subj, "files": []}
            commits.append(cur)
        elif line.strip() and cur is not None:
            parts = line.split("\t")
            if len(parts) == 3:
                cur["files"].append((parts[0], parts[1], parts[2]))
    commits.reverse()  # mais antigo primeiro
    return commits


def read_history(repo, ref, prefix, days):
    """(sha da ponta, commits). A ponta é resolvida UMA vez e o log lê esse sha: o meta nunca diz uma ponta que não foi lida."""
    # vazio → ponta ilegível aborta (não gravo meta sem saber de onde li); falhou → idem, rc 2.
    rc, head = run(["git", "-C", repo, "rev-parse", ref], 30)
    if rc != 0 or not head.strip():
        die(2, "git rev-parse %s falhou" % ref)
    return head.strip(), read_log(repo, head.strip(), prefix, days)


def rel(path, prefix):
    p = prefix.rstrip("/") + "/"
    return path[len(p):] if path.startswith(p) else None


def group_beads(commits, prefix, ex):
    groups = {}
    for i, c in enumerate(commits):
        m = BEAD_RE.match(c["subject"]) or REVERT_RE.match(c["subject"])  # o Revert entra na bead que desfaz: classify a exclui
        if not m:
            ex["sem_bead_no_assunto"] += 1
            continue
        groups.setdefault(m.group(1), []).append(i)
    return groups


def classify(bead, idxs, commits, prefix):
    """None se a bead serve; senão o motivo (string) da exclusão."""
    cs = [commits[i] for i in idxs]
    if any(c["subject"].lower().startswith("revert") for c in cs):
        return "revert"
    tests, prod, other, lines = set(), set(), False, 0
    for c in cs:
        for add, dele, path in c["files"]:
            r = rel(path, prefix)
            if r is None or not r.startswith(ALLOW_ROOTS):
                other = True
                continue
            if add == "-" or dele == "-":
                return "binario"
            if r.endswith(".selftest.sh"):
                tests.add(r)
            elif r.startswith(PROD_ROOTS) and not r.endswith(".md"):
                prod.add(r)
                lines += int(add) + int(dele)
    if other:
        return "fora_da_allowlist"
    if not tests or not prod:
        return "sem_selftest_ou_sem_producao"
    if (len(cs) > LIMITS["commits"] or len(prod) > LIMITS["prod_files"]
            or len(tests) > LIMITS["test_files"] or lines > LIMITS["prod_lines"]):
        return "grande_demais"
    touched = {p for c in cs for _, _, p in c["files"]}
    own = set(idxs)
    for j in range(idxs[0] + 1, idxs[-1]):
        if j not in own and any(p in touched for _, _, p in commits[j]["files"]):
            return "intercalada"
    return None


def read_bead(bd_cmd, bead):
    """(estado, dict) — estado: ok | ilegivel (bd mudo, json ruim, campo faltando)."""
    # vazio → 'ilegivel' (bead sem corpo não é bead); falhou/ilegível → 'ilegivel' e CONTADO, a tarefa não entra.
    rc, out = run(bd_cmd + ["show", bead, "--json"], 60)
    if rc != 0:
        return "ilegivel", {}
    try:
        data = json.loads(out)
    except ValueError:
        return "ilegivel", {}
    if isinstance(data, list):
        data = data[0] if data else None
    if not isinstance(data, dict) or "title" not in data or "status" not in data:
        return "ilegivel", {}
    return "ok", data


def role_of(b):
    """Papel de quem construiu a bead. A bead FECHADA perde o assignee (13 de 13 medidas em 28/11) e quase sempre o gc.routed_to (12 de 13);
    gc.session_name sobra em todas (13 de 13)."""
    # vazio → "sem-papel" (nenhuma fonte diz quem construiu); falhou/ilegível (campo que não é texto) → conta como vazio, não derruba a leitura.
    meta = b.get("metadata") if isinstance(b.get("metadata"), dict) else {}
    for src in (meta.get("gc.session_name"), b.get("assignee"), meta.get("gc.routed_to")):
        if isinstance(src, str) and src.strip():
            hit = ROLE_RE.search(src)
            return hit.group(1) if hit else "outro"
    return "sem-papel"


def take_lock(path):
    """Trava de instância única (flock). Ocupada → espera até LOCK_WAIT_S e sai com rc 4, nada trocado; não abrir/travar → OSError."""
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    end = time.monotonic() + LOCK_WAIT_S
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= end:
                die(4, "%s ocupada há %s s: outra rodada está gravando o acervo; nada foi trocado" % (path, LOCK_WAIT_S))
            time.sleep(0.2)


def stage(path, data, tmps):
    """Grava `data` (bytes) num temporário ao lado de `path` e o anota em `tmps`: quem falhar depois limpa a lista inteira."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-corpus-")
    tmps.append(tmp)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return tmp


def publish(out, body, meta):
    """Grava o par (acervo, meta) sem deixar meio par: prepara os DOIS temporários, guarda o acervo antigo, troca o acervo e por
    ÚLTIMO o meta (o selo); se o meta não troca, o acervo antigo volta. rc 4 = o par anterior ficou como estava; a exceção é a falha
    dupla (o meta não troca E o antigo não volta): aí a mensagem diz PAR TORTO e onde o acervo antigo ficou guardado."""
    out = os.path.abspath(out)
    mp, tmps, lock = out + ".meta.json", [], None
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        lock = take_lock(out + ".lock")
        new_t, new_m = stage(out, body, tmps), stage(mp, meta, tmps)
        # vazio → não há acervo anterior (desfazer = apagar o novo); falhou/ilegível → sem como guardar o antigo: rc 4, nada trocado.
        old = None
        if os.path.exists(out):
            old = stage(out, b"", tmps)
            shutil.copyfile(out, old)
        os.replace(new_t, out)
        try:
            os.replace(new_m, mp)
        except OSError as e:
            try:
                if old:
                    os.replace(old, out)
                else:
                    os.unlink(out)
            except OSError as e2:
                if old:
                    tmps.remove(old)  # agora é a ÚNICA cópia do acervo anterior: o finally não pode apagá-la
                die(4, "PAR TORTO em %s: o meta não trocou (%s) e o acervo anterior não voltou (%s)%s"
                    % (out, e, e2, "; ele está em " + old if old else ""))
            raise
    except OSError as e:
        die(4, "não consegui gravar %s: %s (o par anterior continua como estava)" % (out, e))
    finally:
        for t in tmps:
            try:
                os.unlink(t)
            except OSError:
                pass
        if lock is not None:
            os.close(lock)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    city = os.environ.get("GC_CITY_PATH", "")
    ap.add_argument("--repo", default=os.path.dirname(city) if city else ".")
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--prefix", default=os.path.basename(city) if city else ".gascity-gastown-hq")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--min", type=int, default=20)
    ap.add_argument("--salt", default="battery-v1")
    ap.add_argument("--oversample", type=int, default=3)
    ap.add_argument("--bd", default="bd")
    ap.add_argument("--out", default=os.path.join(city, ".gc/agent-battery/tasks.jsonl") if city else "")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.out and not a.dry_run:
        die(2, "sem --out e sem GC_CITY_PATH")
    if a.n < 1 or a.min < 1 or a.min > a.n or a.days < 1 or a.oversample < 1:
        die(2, "--n/--min/--days/--oversample inválidos (precisa n>=min>=1)")
    # vazio/ilegível (aspas desbalanceadas) → uso errado, rc 2, antes de ler qualquer coisa; nunca um bd "que não respondeu" (rc 5).
    try:
        bd_cmd = shlex.split(a.bd)
    except ValueError:
        bd_cmd = []
    if not bd_cmd:
        die(2, "--bd vazio ou com aspas desbalanceadas: %r" % a.bd)
    if os.environ.get("GC_CITY_PATH") and a.bd == "bd":
        bd_cmd = ["bd", "-C", os.environ["GC_CITY_PATH"]]

    ex = {k: 0 for k in ("sem_bead_no_assunto", "revert", "binario", "fora_da_allowlist", "sem_selftest_ou_sem_producao",
                         "grande_demais", "intercalada", "bead_ilegivel", "bead_nao_fechada", "sem_enunciado",
                         "dado_pessoal")}
    head, commits = read_history(a.repo, a.ref, a.prefix, a.days)
    if not commits:
        die(3, "nenhum commit em %s nos últimos %d dias; nada a escolher" % (a.ref, a.days))

    groups = group_beads(commits, a.prefix, ex)
    eligible = []
    for bead, idxs in groups.items():
        why = classify(bead, idxs, commits, a.prefix)
        if why:
            ex[why] += 1
        else:
            eligible.append((hashlib.sha256((a.salt + bead).encode()).hexdigest(), bead, idxs))
    eligible.sort()

    tasks, tried = [], 0
    for _, bead, idxs in eligible:
        if len(tasks) >= a.n or tried >= a.n * a.oversample:
            break
        tried += 1
        st, b = read_bead(bd_cmd, bead)
        if st != "ok":
            ex["bead_ilegivel"] += 1
            continue
        if b.get("status") != "closed":
            ex["bead_nao_fechada"] += 1
            continue
        title, desc = str(b.get("title") or ""), str(b.get("description") or "")
        if len(desc.strip()) < 40:
            ex["sem_enunciado"] += 1
            continue
        cs = [commits[i] for i in idxs]
        if PII_RE.search("\n".join([title, desc] + [c["subject"] for c in cs])):  # o assunto dos commits também vai no acervo
            ex["dado_pessoal"] += 1
            continue
        tfiles = sorted({rel(p, a.prefix) for c in cs for _, _, p in c["files"] if p.endswith(".selftest.sh")})
        pfiles = sorted({rel(p, a.prefix) for c in cs for _, _, p in c["files"]
                         if rel(p, a.prefix).startswith(PROD_ROOTS) and not p.endswith((".selftest.sh", ".md"))})
        tasks.append({
            "task_id": bead, "bead": bead, "title": title, "description": desc, "issue_type": b.get("issue_type", ""),
            "role": role_of(b), "base_sha": cs[0]["parent"], "fix_sha": cs[-1]["sha"],
            "commits": [{"sha": c["sha"], "subject": c["subject"]} for c in cs],
            "prod_files": pfiles, "test_files": tfiles,
            "success": {"kind": "selftest-fail-to-pass", "commands": ["bash " + t for t in tfiles]},
        })

    roles = {}
    for t in tasks:
        roles[t["role"]] = roles.get(t["role"], 0) + 1
    summary = {"ref": a.ref, "head": head, "commits_lidos": len(commits), "beads_vistas": len(groups),
               "elegiveis": len(eligible), "leituras_de_bead": tried, "selecionadas": len(tasks), "por_papel": roles,
               "excluidas": ex, "dry_run": a.dry_run}
    if tried and ex["bead_ilegivel"] * 2 >= tried:
        print(json.dumps(summary, ensure_ascii=False))
        die(5, "bd não respondeu em %d de %d leituras; não sei dizer se o filtro é rígido — nada escrito" % (ex["bead_ilegivel"], tried))
    if len(tasks) < a.min:
        print(json.dumps(summary, ensure_ascii=False))
        die(3, "só %d tarefas (mínimo %d); o acervo anterior, se houver, fica como está" % (len(tasks), a.min))
    if a.dry_run:
        print(json.dumps(summary, ensure_ascii=False))
        return 0

    body = "".join(json.dumps(t, ensure_ascii=False, sort_keys=True) + "\n" for t in tasks).encode("utf-8")
    sha = hashlib.sha256(body).hexdigest()
    summary.update({"sha256": sha, "out": a.out, "gerado_em": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "params": {"days": a.days, "n": a.n, "min": a.min, "salt": a.salt, "prefix": a.prefix}})
    publish(a.out, body, (json.dumps(summary, ensure_ascii=False, indent=1) + "\n").encode("utf-8"))
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
