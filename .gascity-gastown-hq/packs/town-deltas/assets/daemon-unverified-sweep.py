#!/usr/bin/env python3
"""daemon-unverified-sweep.py — vigia de `delivery:daemon-unverified` (ga-iyfe83, parte 3 da ga-29ssni). FATIA 1: núcleo.

O PROBLEMA. O gate fecha um bead com o rótulo `delivery:daemon-unverified` quando o código mergeado pode estar
DORMENTE: o daemon que o executa não foi (ou não pôde ser) confirmado reiniciado depois do merge. ~300 beads
carregam o rótulo e NADA o lia — o rótulo era um lembrete que ninguém consultava.

O QUE ESTE VIGIA FAZ. Para cada bead fechado com o rótulo decide EXATAMENTE UM de três estados, que nunca colapsam:

  CONFIRMADO          o daemon dono do código mergeado subiu DEPOIS do merge (início do processo vivo > merge).
  AINDA NÃO VISTO     subiu ANTES do merge, ou o daemon não está carregado / não tem processo.
  NÃO CONSEGUI SABER  sem sha de merge, sem daemon identificável, ou a leitura falhou.

Regra de ouro (E12: "vazio ≠ falhou"): NÃO CONSEGUI SABER é o estado de qualquer dúvida. Leitura que falhou
(bd/launchctl/ps/git, timeout, saída ilegível) NUNCA vira CONFIRMADO — e também não vira "AINDA NÃO VISTO" nem
"nenhum daemon": é NÃO CONSEGUI SABER, com o motivo (`reason`) dizendo qual leitura quebrou.
Precedência quando um bead tem vários daemons donos: AINDA NÃO VISTO > NÃO CONSEGUI SABER > CONFIRMADO
(um dono sem reinício já basta pra o código estar dormente; CONFIRMADO exige TODOS os donos confirmados).

DETECTA, NÃO AGE. Não reinicia nada e não roda daemon-refresh: o Mayor / dono do daemon decide a partir do relatório.
As únicas chamadas ao launchd são `launchctl list <label>` (leitura).

Motivos (`reason`):
  CONFIRMADO:  started-after-merge
  AINDA:       started-before-merge · not-loaded · loaded-no-pid
  NCS (conteúdo, rc 0):        no-merge-sha · no-daemon · sha-not-on-disk · not-keepalive
  NCS (leitura quebrou, rc 3): launchctl-read-failed · ps-read-failed · git-read-failed · bad-timestamp ·
                               plist-read-failed · status-unknown · internal-error
  Uma LOJA que não listou não é uma loja com zero beads: fica em `stores` (ok=false) no relatório e o rc é 3.

ESCOPO DESTA FATIA (ga-iyfe83.1; o que ainda não entrou é NÃO CONSEGUI SABER com motivo, nunca CONFIRMADO):
  - o sha do merge vem só do `close_reason` (`sha=<40hex>`); sem ele → no-merge-sha. (.2: marcador do gate.)
  - só julga daemon KeepAlive (início do processo vivo × merge); periódico / por evento → not-keepalive. (.2)
  - dono = o plist que roda exatamente um arquivo da entrega. (.2: closure do deploy_deps.json.)
  - dry-run: escreve `daemon-unverified-sweep-latest.json` e imprime as contagens. (.3: relatório legível, aviso, plist.)

LIMITES CONHECIDOS (o relatório é uma triagem, não uma prova):
  - "subiu depois do merge" é NECESSÁRIO, não SUFICIENTE: se o checkout vivo só recebeu o código depois do merge
    (pull atrasado), um daemon que subiu entre o merge e o pull sai CONFIRMADO sem ter rodado o código novo.
  - O sha do merge é só a PONTA da branch. Numa entrega em fast-forward com vários commits, os arquivos dos
    commits anteriores só entram na conta porque o script TAMBÉM busca commits cuja mensagem cita o id do bead
    (janela de 30 dias antes do merge). Commit que não cita o bead e não é a ponta não é visto.
  - O dono é achado pelo caminho ABSOLUTO do arquivo em `ProgramArguments`. Plist que roda o arquivo por `Program`, ou
    dentro de `bash -c "…"`, não é visto como dono (hoje: nenhum `Program` e um só KeepAlive com `-c`, o dolt-server).

COMO RODA. Dry-run: escreve `daemon-unverified-sweep-latest.json` em .gc/logs e imprime uma linha com as contagens por estado.
Saída: 0 = leu tudo · 3 = alguma leitura falhou (ver `stores` / `reason` no JSON).
Sementes de teste: DUS_BD, DUS_LAUNCHCTL, DUS_PS, DUS_STORES, DUS_OUT_DIR, DUS_NOW…
"""
import argparse
import datetime
import glob
import json
import os
import plistlib
import re
import subprocess
import sys
import time

CONFIRMADO = "CONFIRMADO"
AINDA = "AINDA NÃO VISTO"
NCS = "NÃO CONSEGUI SABER"
OUT = "FORA DE ESCOPO"      # tem o rótulo mas não está fechado: fica FORA dos três estados (não é um quarto estado)

DAY = 86400
# Janela em que se procuram os OUTROS commits do mesmo bead (entrega em fast-forward com vários commits).
BRANCH_WINDOW = 30 * DAY

SHA_RE = re.compile(r"sha=([0-9a-f]{40})")

# NCS cujo motivo é "a leitura quebrou" (≠ NCS de conteúdo): fazem o vigia sair com rc 3, nunca com zero.
READ_FAILED = {"launchctl-read-failed", "ps-read-failed", "git-read-failed", "bad-timestamp", "plist-read-failed",
               "internal-error", "status-unknown"}


class ReadFailed(Exception):
    """Uma leitura (bd/launchctl/ps/git) quebrou — vira NÃO CONSEGUI SABER com `reason`, nunca um estado 'bom'."""

    def __init__(self, reason, detail=""):
        Exception.__init__(self, reason)
        self.reason = reason
        self.detail = detail


def env(name, default):
    return os.environ.get(name, default)


HOME = os.path.expanduser("~")
CITY = os.environ.get("GC_CITY_PATH", os.path.join(HOME, "gt", ".gascity-gastown-hq"))
# nome|loja do bd|checkout vivo de onde os daemons rodam. property_scrapers roda do runtime
# (~/.property-scrapers/runtime/main), não do repo bare do rig.
DEFAULT_STORES = ";".join([
    "gascity|%s|%s" % (CITY, os.path.join(HOME, "gt")),
    "whatsapp_automation|%s|%s" % (os.path.join(HOME, "gt", "whatsapp_automation"), os.path.join(HOME, "gt", "whatsapp_automation")),
    "property_scrapers|%s|%s" % (os.path.join(HOME, "gt", "property_scrapers"), os.path.join(HOME, ".property-scrapers", "runtime", "main")),
])


def run(cmd, timeout=None):
    e = dict(os.environ)
    e["LC_ALL"] = "C"          # `ps -o lstart=` em C: "Fri Oct 16 10:30:00 2026", independente do locale
    return subprocess.run(cmd, capture_output=True, text=True, env=e,
                          timeout=timeout if timeout is not None else int(env("DUS_CMD_TIMEOUT", "60")))


def parse_iso(s):
    """'2026-10-16T05:24:43Z' (ou com fração / offset) → epoch UTC. Ilegível → ValueError (quem chama trata)."""
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s)   # python 3.9: fração só com 3 ou 6 dígitos
    dt = datetime.datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())


def ts(s):
    try:
        return parse_iso(s)
    except (ValueError, TypeError, AttributeError):
        raise ReadFailed("bad-timestamp", repr(s))


def load_stores():
    stores = []
    for ent in env("DUS_STORES", DEFAULT_STORES).split(";"):
        if ent.strip():
            name, store, repo = ent.strip().split("|")
            stores.append({"name": name, "store": store, "repo": repo})
    return stores


# ---- leituras com retry ---------------------------------------------------

def bd_list(store, labels):
    """`bd -C <store> list --label … --all --json --limit 0` com retry. Falha sustentada → ReadFailed('bd-failed').

    A máquina vive com load ~70 e o Dolt estoura timeout de leitura (`i/o timeout`, `invalid connection`): UMA
    falha não pode virar "loja sem beads" — por isso retry, e depois de esgotar, ReadFailed (≠ lista vazia)."""
    cmd = [env("DUS_BD", "bd"), "-C", store, "list"]
    for l in labels:
        cmd += ["--label", l]
    cmd += ["--all", "--json", "--limit", "0"]
    attempts = int(env("DUS_RETRIES", "3"))
    last = ""
    for i in range(attempts):
        try:
            r = run(cmd, timeout=int(env("DUS_BD_TIMEOUT", "100")))
            if r.returncode == 0:
                data = json.loads(r.stdout)
                if isinstance(data, list):
                    return data
                last = "json não é lista"
            else:
                last = (r.stderr or r.stdout).strip()[-200:]
        except (subprocess.TimeoutExpired, ValueError, OSError) as e:
            last = "%s: %s" % (type(e).__name__, e)
        if i + 1 < attempts:
            time.sleep(float(env("DUS_RETRY_SLEEP", "4")))
    raise ReadFailed("bd-failed", last)


def merge_of(bead):
    """O sha mergeado e QUANDO desembarcou, lidos do close_reason (`sha=<40hex>`; tempo = closed_at do bead, que é >= o
    merge: erra pro lado conservador). Sem sha ali → None (NÃO CONSEGUI SABER): esta fatia não consulta o marcador.
    Sha sem `closed_at` não é "sem sha": o sha existe e o QUANDO faltou → ts() levanta bad-timestamp (leitura que falhou)."""
    m = SHA_RE.search(bead.get("close_reason") or "")
    if m:
        return m.group(1), ts(bead.get("closed_at")), "close_reason"
    return None


# ---- git ------------------------------------------------------------------

def sha_on_disk(repo, sha):
    try:
        # `cat-file -e` dá 128 tanto pra sha ausente quanto pra repo quebrado; `rev-parse --verify --quiet` dá 1 só
        # pro ausente. Repo quebrado é leitura que falhou (git-read-failed), não "sha fora do disco".
        c = run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", sha + "^{commit}"])
        if c.returncode == 1:
            return False
        if c.returncode != 0:
            raise ReadFailed("git-read-failed", c.stderr.strip()[-200:] or "rev-parse rc=%d" % c.returncode)
        a = run(["git", "-C", repo, "merge-base", "--is-ancestor", sha, "HEAD"])
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed("git-read-failed", str(e))
    if a.returncode == 0:
        return True
    if a.returncode == 1:
        return False
    raise ReadFailed("git-read-failed", a.stderr.strip()[-200:])


def changed_files(repo, sha):
    try:
        r = run(["git", "-C", repo, "diff-tree", "-r", "--name-only", "--no-commit-id", "-m", "--first-parent", sha])
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed("git-read-failed", str(e))
    if r.returncode != 0:
        raise ReadFailed("git-read-failed", r.stderr.strip()[-200:])
    return [x for x in r.stdout.splitlines() if x]


def delivery_files(repo, sha, bead_id, merged_at):
    """Arquivos da ENTREGA: os da ponta (`sha`) + os dos outros commits que citam o bead.

    O gate mergeia em fast-forward: `sha` é só a PONTA da branch, e olhar só o diff dela perde os donos dos commits
    anteriores — o erro perigoso (falso CONFIRMADO). Cada commit cita o id do bead (convenção `fix(ga-xxx): …`);
    mais arquivos só acrescentam donos, o que empurra pra AINDA/NCS — nunca pra CONFIRMADO."""
    files = set(changed_files(repo, sha))
    try:
        r = run(["git", "-C", repo, "log", "--fixed-strings", "--grep=" + bead_id, "--format=%H",
                 "--since=%d" % (merged_at - BRANCH_WINDOW), sha])
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed("git-read-failed", str(e))
    if r.returncode != 0:
        raise ReadFailed("git-read-failed", r.stderr.strip()[-200:])
    for c in r.stdout.split():
        if c != sha:
            files |= set(changed_files(repo, c))
    return sorted(files)


# ---- donos (daemons) ------------------------------------------------------

def read_plist(path):
    """(plist, via_plutil). O expat do python é estrito (recusa `--` dentro de comentário XML, que o launchd e o plutil
    aceitam): se ele recusar, o `plutil` decide. Os dois recusarem → exceção (quem chama conta como ilegível)."""
    try:
        with open(path, "rb") as f:
            return plistlib.load(f), False
    except Exception:
        r = run([env("DUS_PLUTIL", "plutil"), "-convert", "xml1", "-o", "-", path])
        if r.returncode != 0:
            raise ValueError("plutil rc=%d" % r.returncode)
        return plistlib.loads(r.stdout.encode("utf-8")), True


def load_plists():
    """({label: plist}, {"unreadable", "no_label", "via_plutil": [arquivos]}). Plist que não lê NÃO some em silêncio: vira
    dúvida (plist-read-failed). Plist lido mas sem Label não é daemon (o launchd não o carrega): fica listado à parte."""
    plists, info = {}, {"unreadable": [], "no_label": [], "via_plutil": []}
    for p in sorted(glob.glob(os.path.join(env("DUS_LAUNCH_AGENTS_DIR", os.path.join(HOME, "Library", "LaunchAgents")), "*.plist"))):
        name = os.path.basename(p)
        try:
            pl, via_plutil = read_plist(p)
            label = pl.get("Label")
        except Exception:
            info["unreadable"].append(name)
            continue
        if via_plutil:
            info["via_plutil"].append(name)
        if isinstance(label, str):
            plists[label] = pl
        else:
            info["no_label"].append(name)
    return plists, info


def owners_of(files, repo, plists):
    """Labels dos daemons donos dos `files`: o plist roda exatamente esse arquivo (ProgramArguments)."""
    real = os.path.realpath(repo)
    fileset = set(files)
    labels = set()
    for label, pl in plists.items():
        progs = {os.path.relpath(os.path.realpath(a), real) for a in pl.get("ProgramArguments", []) if a.startswith("/")}
        if progs & fileset:
            labels.add(label)
    return sorted(labels)


def launchctl_pid(label):
    """('not-loaded', None) | ('loaded', pid|None). Erro de leitura → ReadFailed (≠ not-loaded)."""
    try:
        r = run([env("DUS_LAUNCHCTL", "launchctl"), "list", label])
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed("launchctl-read-failed", str(e))
    if r.returncode == 0 and '"Label"' in r.stdout:
        m = re.search(r'"PID"\s*=\s*(\d+);', r.stdout)
        return "loaded", (m.group(1) if m else None)
    if "Could not find service" in (r.stderr + r.stdout):
        return "not-loaded", None
    raise ReadFailed("launchctl-read-failed", (r.stderr or r.stdout).strip()[-200:])


def process_start(pid):
    try:
        r = run([env("DUS_PS", "ps"), "-o", "lstart=", "-p", pid])
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed("ps-read-failed", str(e))
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        raise ReadFailed("ps-read-failed", "ps rc=%d, sem saída (processo sumiu?)" % r.returncode)
    try:
        return int(time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y")))
    except ValueError:
        raise ReadFailed("ps-read-failed", "lstart ilegível: %r" % out)


def owner_state(plist, merged_at):
    label = plist["Label"]
    status, pid = launchctl_pid(label)
    if status == "not-loaded":
        return AINDA, "not-loaded"
    if not plist.get("KeepAlive"):
        return NCS, "not-keepalive"         # periódico / por evento: esta fatia só julga quem vive até alguém matar
    if pid is None:
        return AINDA, "loaded-no-pid"
    started = process_start(pid)
    if started > merged_at:
        return CONFIRMADO, "started-after-merge"
    return AINDA, "started-before-merge"


# ---- classificação --------------------------------------------------------

def classify(bead, repo, plists, unreadable):
    try:
        got = merge_of(bead)
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    if not got:
        return NCS, "no-merge-sha", [], {}
    sha, merged_at, _src = got
    try:
        if not sha_on_disk(repo, sha):
            return NCS, "sha-not-on-disk", [], {}
        files = delivery_files(repo, sha, bead["id"], merged_at)
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    owners = owners_of(files, repo, plists)
    results = []
    for label in owners:
        try:
            st, why = owner_state(plists[label], merged_at)
        except ReadFailed as e:
            st, why = NCS, e.reason
        results.append((label, st, why))
    # Um plist que não consegui ler pode ser o dono: enquanto existir, ninguém é CONFIRMADO só porque os outros foram.
    results += [("<plist ilegível: %s>" % n, NCS, "plist-read-failed") for n in unreadable]
    if not results:
        return NCS, "no-daemon", [], {}
    labels = [r[0] for r in results]
    detail = {r[0]: [r[1], r[2]] for r in results}
    for want in (AINDA, NCS):                     # precedência: AINDA > NCS > CONFIRMADO
        hit = [r for r in results if r[1] == want]
        if hit:
            return want, hit[0][2], labels, detail
    return CONFIRMADO, results[0][2], labels, detail   # todos CONFIRMADO: o motivo do primeiro dono basta


def main(argv):
    ap = argparse.ArgumentParser(description="vigia de delivery:daemon-unverified (detecta, não age)")
    ap.parse_args(argv)
    out_dir = env("DUS_OUT_DIR", os.path.join(CITY, ".gc", "logs"))
    os.makedirs(out_dir, exist_ok=True)
    stores = load_stores()
    now = int(env("DUS_NOW", "0")) or int(time.time())
    plists, pinfo = load_plists()
    unreadable = pinfo["unreadable"]
    beads, store_status = [], {}
    for s in stores:
        try:
            labelled = bd_list(s["store"], ["delivery:daemon-unverified"])
        except ReadFailed as e:
            # loja que não leu NÃO é loja com zero beads: fica registrada como falha e o vigia sai com rc 3.
            store_status[s["name"]] = {"ok": False, "error": e.detail or e.reason, "n": 0}
            sys.stderr.write("daemon-unverified-sweep: ERRO — não consegui listar a loja '%s' (%s)\n" % (s["name"], e.detail))
            continue
        store_status[s["name"]] = {"ok": True, "error": "", "n": len(labelled)}
        for b in labelled:
            if not b.get("status"):               # sem status não sei se fechou: dúvida, não "aberto"
                state, reason, owners, detail = NCS, "status-unknown", [], {}
            elif b["status"] != "closed":
                state, reason, owners, detail = OUT, "not-closed", [], {}
            else:
                try:
                    state, reason, owners, detail = classify(b, s["repo"], plists, unreadable)
                except Exception as e:                                   # um bead estranho não derruba os outros
                    state, reason, owners, detail = NCS, "internal-error", [], {}
                    sys.stderr.write("daemon-unverified-sweep: bead %s: %s: %s\n" % (b.get("id"), type(e).__name__, e))
            beads.append({"id": b["id"], "rig": s["name"], "state": state, "reason": reason, "owners": owners,
                          "owner_states": detail})
    counts = {CONFIRMADO: 0, AINDA: 0, NCS: 0, OUT: 0}
    for b in beads:
        counts[b["state"]] += 1
    report_path = os.path.join(out_dir, "daemon-unverified-sweep-latest.json")
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump({"counts": counts, "stores": store_status, "plists": dict(pinfo, n=len(plists)), "beads": beads},
                  f, ensure_ascii=False, indent=1)
    broken = any(not v["ok"] for v in store_status.values()) or any(b["reason"] in READ_FAILED for b in beads)
    print("%s daemon-unverified-sweep: %s · relatório: %s" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        " · ".join("%s=%d" % (k, counts[k]) for k in (CONFIRMADO, AINDA, NCS, OUT)), report_path))
    return 3 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
