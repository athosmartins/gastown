#!/usr/bin/env python3
"""agent-battery-corpus.py — monta o acervo de tarefas da bateria noturna de agentes (ga-hyp55ss, fatia 1).

## Contents
  Uso · O que entra · O que NÃO entra · Saída · Códigos de saída

USO: agent-battery-corpus.py [--repo DIR] [--ref REF] [--prefix SUBPASTA] [--days N] [--n N] [--min N]
        [--salt S] [--oversample K] [--bd CMD] [--out ARQ] [--dry-run]
  Lê o histórico git já MERGEADO (o que o gate empurrou para a main) e devolve até --n tarefas (padrão 40) em JSONL.
  Cada tarefa = uma bead fechada cuja entrega mexeu em código de produção E trouxe um `*.selftest.sh`: o critério de
  sucesso é verificável por máquina (o selftest da entrega REPROVA em base_sha e PASSA com o patch certo). Esta fatia só
  MONTA o acervo; quem confere "reprova na base / passa no fix" e roda o agente é a fatia 2 (docs/runbooks/agent-battery.md).

O QUE ENTRA (todas as condições): bead `ga-*` citada no escopo do assunto do commit (`fix(ga-x): …`); dentro dos --days
  (padrão 60); pelo menos 1 `*.selftest.sh` e 1 arquivo de produção (scripts/, packs/, formulas/, commands/); no máximo 4 commits,
  6 arquivos de produção, 3 selftests e 300 linhas de produção; nenhum commit de outra bead mexeu nos mesmos arquivos entre o
  primeiro e o último commit da bead (senão base→fix não isola a entrega); bead legível, fechada, com enunciado.
O QUE NÃO ENTRA: arquivo fora da allowlist (city.toml, agents/, .beads, .gc, dados), binário, bead reaberta, qualquer
  telefone, CPF ou e-mail no título/enunciado (zero tolerância: aqui um acerto basta, ao contrário do hetzner-pii-scan.py,
  que caça LISTA), `revert`. Cada exclusão é CONTADA por motivo na saída; nada some em silêncio.
SAÍDA: JSONL em --out (padrão $GC_CITY_PATH/.gc/agent-battery/tasks.jsonl, fora do git) + <out>.meta.json (sha256 do JSONL,
  parâmetros, contagens, sha da ponta lida). Escrita atômica (tmp + rename). Resumo JSON no stdout.
CÓDIGOS: 0 ok · 2 uso errado ou git ilegível (nada escrito) · 3 menos tarefas que --min (nada escrito, o acervo antigo fica)
  · 4 não consegui gravar · 5 `bd` não respondeu em metade ou mais das leituras (não sei dizer se o filtro é rígido: nada escrito).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

BEAD_RE = re.compile(r"^[a-z]+\((ga-[a-z0-9]+(?:\.[0-9]{1,4})*)\)")
ALLOW_ROOTS = ("scripts/", "packs/", "formulas/", "commands/", "docs/")
PROD_ROOTS = ("scripts/", "packs/", "formulas/", "commands/")
# Zero tolerância: um telefone, CPF ou e-mail no enunciado tira a tarefa (dado de lead não vai para o nó).
PII_RE = re.compile(
    r"(?<![0-9])\+?55 ?\(?[1-9][0-9]\)? ?9?[0-9]{4}-?[0-9]{4}(?![0-9])"
    r"|\([1-9][0-9]\) ?9?[0-9]{4}-[0-9]{4}(?![0-9])"
    r"|(?<![0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}(?![0-9])"
    r"|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
)
LIMITS = {"commits": 4, "prod_files": 6, "test_files": 3, "prod_lines": 300}


def die(code, msg):
    print("agent-battery-corpus: " + msg, file=sys.stderr)
    sys.exit(code)


def run(cmd, timeout):
    """(rc, stdout) — rc None = não rodou (binário ausente) ou estourou o prazo: 'não consegui saber', nunca vazio."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout


def read_log(repo, ref, prefix, days):
    # vazio → devolve [] e o chamador sai com rc 3 (nada a escolher); falhou/ilegível → die(2), nada é escrito.
    since = "--since=%d days ago" % days
    rc, out = run(["git", "-C", repo, "log", ref, since, "--no-merges", "--numstat",
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


def rel(path, prefix):
    p = prefix.rstrip("/") + "/"
    return path[len(p):] if path.startswith(p) else None


def group_beads(commits, prefix, ex):
    groups = {}
    for i, c in enumerate(commits):
        m = BEAD_RE.match(c["subject"])
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
    meta = b.get("metadata") if isinstance(b.get("metadata"), dict) else {}
    s = " ".join(str(x) for x in (meta.get("gc.routed_to", ""), b.get("assignee", "")))
    for key, role in (("wa-worker", "wa-worker"), ("ps-worker", "ps-worker"), ("dog", "dog")):
        if key in s:
            return role
    return "sem-papel" if not s.strip() else "outro"


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

    ex = {k: 0 for k in ("sem_bead_no_assunto", "revert", "binario", "fora_da_allowlist", "sem_selftest_ou_sem_producao",
                         "grande_demais", "intercalada", "bead_ilegivel", "bead_nao_fechada", "sem_enunciado",
                         "dado_pessoal")}
    commits = read_log(a.repo, a.ref, a.prefix, a.days)
    if not commits:
        die(3, "nenhum commit em %s nos últimos %d dias; nada a escolher" % (a.ref, a.days))
    # vazio → ponta ilegível aborta (não gravo meta sem saber de onde li); falhou → idem, rc 2.
    rc, head = run(["git", "-C", a.repo, "rev-parse", a.ref], 30)
    if rc != 0 or not head.strip():
        die(2, "git rev-parse %s falhou" % a.ref)

    groups = group_beads(commits, a.prefix, ex)
    eligible = []
    for bead, idxs in groups.items():
        why = classify(bead, idxs, commits, a.prefix)
        if why:
            ex[why] += 1
        else:
            eligible.append((hashlib.sha256((a.salt + bead).encode()).hexdigest(), bead, idxs))
    eligible.sort()

    bd_cmd = a.bd.split()
    if os.environ.get("GC_CITY_PATH") and a.bd == "bd":
        bd_cmd = ["bd", "-C", os.environ["GC_CITY_PATH"]]
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
        if PII_RE.search(title + "\n" + desc):
            ex["dado_pessoal"] += 1
            continue
        cs = [commits[i] for i in idxs]
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
    summary = {"ref": a.ref, "head": head.strip(), "commits_lidos": len(commits), "beads_vistas": len(groups),
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

    body = "".join(json.dumps(t, ensure_ascii=False, sort_keys=True) + "\n" for t in tasks)
    sha = hashlib.sha256(body.encode()).hexdigest()
    summary.update({"sha256": sha, "out": a.out, "gerado_em": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "params": {"days": a.days, "n": a.n, "min": a.min, "salt": a.salt, "prefix": a.prefix}})
    try:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        for path, text in ((a.out, body), (a.out + ".meta.json", json.dumps(summary, ensure_ascii=False, indent=1) + "\n")):
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".tmp-corpus-")
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp, path)
    except OSError as e:
        die(4, "não consegui gravar %s: %s" % (a.out, e))
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
