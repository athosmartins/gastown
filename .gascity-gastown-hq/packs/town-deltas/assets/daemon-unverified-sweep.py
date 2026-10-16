#!/usr/bin/env python3
"""daemon-unverified-sweep.py — vigia semanal de `delivery:daemon-unverified` (ga-iyfe83, parte 3 da ga-29ssni).

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
  CONFIRMADO:  started-after-merge · period-elapsed
  AINDA:       started-before-merge · not-loaded · loaded-no-pid · period-not-elapsed
  NCS (conteúdo, rc 0):        no-merge-sha · no-daemon · sha-not-on-disk · event-driven · unknown-kind
  NCS (leitura quebrou, rc 3): marker-read-failed · launchctl-read-failed · ps-read-failed · git-read-failed ·
                               bad-timestamp · plist-read-failed · deps-read-failed · deadline-exceeded · internal-error
  Uma LOJA que não listou não é uma loja com zero beads: fica em `stores` (ok=false) no relatório e o rc é 3.

LIMITES CONHECIDOS (o relatório é uma triagem, não uma prova):
  - "subiu depois do merge" é NECESSÁRIO, não SUFICIENTE: se o checkout vivo só recebeu o código depois do merge
    (pull atrasado), um daemon que subiu entre o merge e o pull sai CONFIRMADO sem ter rodado o código novo.
  - O sha do marcador do gate é só a PONTA da branch. Numa entrega em fast-forward com vários commits, os arquivos dos
    commits anteriores só entram na conta porque o script TAMBÉM busca commits cuja mensagem cita o id do bead
    (janela de 30 dias antes do merge). Commit que não cita o bead e não é a ponta não é visto.
  - Daemon event-driven (WatchPaths/QueueDirectories) e de tipo desconhecido caem em NÃO CONSEGUI SABER: não há
    início de processo nem período que prove um disparo depois do merge.

COMO RODA. Sem `--notify` é dry-run: escreve o relatório e NÃO avisa nem toca no baseline. Com `--notify` manda UMA
notificação, só se há AINDA NÃO VISTO novo desde a última execução (baseline em daemon-unverified-sweep.state.json).
Saída: 0 = leu tudo · 3 = alguma leitura falhou (ver `stores` / `reason` no relatório). Uma 2ª instância simultânea sai
sem varrer (flock). Sementes de teste: DUS_BD, DUS_LAUNCHCTL, DUS_PS, DUS_NOTIFY, DUS_STORES, DUS_OUT_DIR, DUS_NOW…
"""
import argparse
import datetime
import fcntl
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
READ_FAILED = {"marker-read-failed", "launchctl-read-failed", "ps-read-failed", "git-read-failed",
               "bad-timestamp", "plist-read-failed", "deps-read-failed", "deadline-exceeded", "internal-error"}


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
# nome|loja do bd|checkout vivo de onde os daemons rodam. A loja HQ é sempre a PRIMEIRA: marcadores de gate de TODOS
# os rigs moram nela. property_scrapers roda do runtime (~/.property-scrapers/runtime/main), não do repo bare do rig.
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
    falha não pode virar "bead sem marcador" — por isso retry, e depois de esgotar, ReadFailed (≠ lista vazia)."""
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


def marker_merge(bead, stores_for_markers):
    """Acha (sha, merge_epoch, fonte) no marcador de gate PASSED do bead (loja HQ primeiro: marcadores de WA/PS moram lá)."""
    found = []
    failed = False
    for st in stores_for_markers:
        try:
            rows = bd_list(st, ["source-bead:" + bead["id"], "type:quality-gate-marker", "gate-status:passed"])
        except ReadFailed:
            failed = True
            continue
        for m in rows:
            sha = SHA_RE.search(m.get("close_reason") or "")
            if sha and m.get("closed_at"):
                try:
                    found.append((ts(m["closed_at"]), sha.group(1)))
                except ReadFailed:
                    failed = True                 # marcador com data ilegível = marcador que não consegui ler
    if found:
        t, sha = max(found)                      # o último desembarque vence (re-merge)
        return sha, t, "marker"
    if failed:
        raise ReadFailed("marker-read-failed")   # ≠ no-merge-sha: erro NÃO é vazio
    return None


def merge_of(bead, hq_store, own_store):
    """O sha mergeado e QUANDO desembarcou. close_reason traz `sha=<40hex>` em boa parte dos beads (tempo = closed_at do
    bead, que é >= o merge: erra pro lado conservador). Sem isso, o marcador de gate; sem isso, NÃO CONSEGUI SABER."""
    m = SHA_RE.search(bead.get("close_reason") or "")
    if m and bead.get("closed_at"):
        return m.group(1), ts(bead["closed_at"]), "close_reason"
    stores = [hq_store] if own_store == hq_store else [hq_store, own_store]
    got = marker_merge(bead, stores)
    if got:
        return got
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

def load_plists():
    """({label: plist}, [arquivos ilegíveis]). Plist que não lê NÃO some em silêncio: vira dúvida (plist-read-failed)."""
    plists, unreadable = {}, []
    for p in sorted(glob.glob(os.path.join(env("DUS_LAUNCH_AGENTS_DIR", os.path.join(HOME, "Library", "LaunchAgents")), "*.plist"))):
        try:
            with open(p, "rb") as f:
                pl = plistlib.load(f)
            plists[pl["Label"]] = pl
        except Exception:
            unreadable.append(os.path.basename(p))
    return plists, unreadable


def load_deps(repo):
    """{arquivo-relativo: {labels}} a partir de <repo>/daemons/deploy_deps.json (closure + assets de cada daemon).
    Ausente = o rig não tem esse mapa (HQ, PS). Presente mas ilegível = dúvida (deps-read-failed), não "sem mapa"."""
    path = os.path.join(repo, "daemons", "deploy_deps.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        out = {}
        for d in data["daemons"].values():
            for rel in list(d.get("closure", [])) + list(d.get("assets", [])):
                out.setdefault(rel, set()).add(d["label"])
        return out
    except Exception as e:
        raise ReadFailed("deps-read-failed", "%s: %s" % (type(e).__name__, e))


def owners_of(files, repo, plists, deps):
    """Labels dos daemons donos dos `files`: (a) o plist roda exatamente esse arquivo; (b) o arquivo está no closure/assets
    do daemon em deploy_deps.json. Label do closure SEM plist nesta máquina não é dono (não roda aqui)."""
    real = os.path.realpath(repo)
    fileset = set(files)
    labels = set()
    for label, pl in plists.items():
        progs = {os.path.relpath(os.path.realpath(a), real) for a in pl.get("ProgramArguments", []) if a.startswith("/")}
        if progs & fileset:
            labels.add(label)
    for f in files:
        labels |= {l for l in deps.get(f, ()) if l in plists}
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


def cal_period(entry):
    """Maior intervalo possível entre duas execuções de UMA entrada de StartCalendarInterval (conservador)."""
    if "Month" in entry:
        return 366 * DAY
    if "Weekday" in entry:
        return 7 * DAY
    if "Day" in entry:
        return 31 * DAY
    if "Hour" in entry:
        return DAY
    if "Minute" in entry:
        return 3600
    return 60


def plist_kind(pl):
    """'long' (KeepAlive: vive até alguém matar) · 'periodic' (processo novo a cada disparo) · 'event' · 'unknown'."""
    if pl.get("KeepAlive"):
        return "long"
    if "StartInterval" in pl or "StartCalendarInterval" in pl:
        return "periodic"
    if pl.get("WatchPaths") or pl.get("QueueDirectories"):
        return "event"
    return "unknown"


def period_seconds(pl):
    """Tempo após o qual PELO MENOS um disparo já ocorreu: o menor dos períodos (vários gatilhos só encurtam o vão)."""
    periods = []
    if "StartInterval" in pl:
        periods.append(int(pl["StartInterval"]))
    cal = pl.get("StartCalendarInterval")
    if cal is not None:
        periods += [cal_period(e) for e in (cal if isinstance(cal, list) else [cal])]
    return min(periods)


def owner_state(plist, merged_at, now):
    label = plist["Label"]
    status, pid = launchctl_pid(label)
    if status == "not-loaded":
        return AINDA, "not-loaded"
    kind = plist_kind(plist)
    if kind == "periodic":
        # cada disparo é um processo novo lendo o código do disco (sha já verificado no disco): basta ter passado
        # um período inteiro desde o merge pra garantir que algum disparo rodou o código novo.
        if now - merged_at >= period_seconds(plist):
            return CONFIRMADO, "period-elapsed"
        return AINDA, "period-not-elapsed"
    if kind == "event":
        return NCS, "event-driven"          # sem período limitado, nada prova que algum evento rodou depois do merge
    if kind == "unknown":
        return NCS, "unknown-kind"
    if pid is None:
        return AINDA, "loaded-no-pid"
    started = process_start(pid)
    if started > merged_at:
        return CONFIRMADO, "started-after-merge"
    return AINDA, "started-before-merge"


# ---- classificação --------------------------------------------------------

def classify(bead, hq_store, own_store, repo, now, plists, unreadable):
    try:
        got = merge_of(bead, hq_store, own_store)
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
    try:
        owners = owners_of(files, repo, plists, load_deps(repo))
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    results = []
    for label in owners:
        try:
            st, why = owner_state(plists[label], merged_at, now)
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


# ---- relatório, estado, aviso --------------------------------------------

def rollup(beads):
    """Por daemon: quantos beads AINDA NÃO VISTO dependem dele — a visão acionável pra quem decide o reinício."""
    out = {}
    for b in beads:
        if b["state"] != AINDA:
            continue
        for label, (st, why) in b["owner_states"].items():
            if st == AINDA:
                d = out.setdefault(label, {"ainda": 0, "beads": [], "reasons": {}})
                d["ainda"] += 1
                d["beads"].append(b["id"])
                d["reasons"][why] = d["reasons"].get(why, 0) + 1
    return out


def render_md(now, counts, store_status, beads, daemons):
    L = ["# Vigia de delivery:daemon-unverified — %s" % time.strftime("%Y-%m-%d", time.localtime(now)), "",
         "DETECTA, NÃO AGE: nada foi reiniciado. Reiniciar é decisão do Mayor / dono do daemon, a partir deste relatório.", "",
         "## Contagens", ""]
    for k in (CONFIRMADO, AINDA, NCS):
        L.append("- %s: %d" % (k, counts[k]))
    L.append("- %s (rótulo, mas não fechado): %d" % (OUT, counts[OUT]))
    L += ["", "Lojas lidas: " + ", ".join("%s %s (n=%d)%s" % (n, "ok" if v["ok"] else "LEITURA FALHOU", v["n"],
                                                             "" if v["ok"] else " — " + str(v["error"])[:120])
                                        for n, v in store_status.items()), ""]
    L += ["## AINDA NÃO VISTO — por daemon (o que reiniciar)", ""]
    if not daemons:
        L += ["(nenhum)", ""]
    for label, d in sorted(daemons.items(), key=lambda kv: (-kv[1]["ainda"], kv[0])):
        L.append("### %s — %d bead(s) [%s]" % (label, d["ainda"], ", ".join("%s×%d" % kv for kv in sorted(d["reasons"].items()))))
        L += ["- " + i for i in sorted(d["beads"])]
        L.append("")
    L += ["## NÃO CONSEGUI SABER — por motivo", ""]
    by = {}
    for b in beads:
        if b["state"] == NCS:
            by.setdefault(b["reason"], []).append(b)
    if not by:
        L += ["(nenhum)", ""]
    for reason, bs in sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        L.append("### %s — %d%s" % (reason, len(bs), "  ← LEITURA QUEBROU" if reason in READ_FAILED else ""))
        L += ["- %s (%s)" % (b["id"], b["rig"]) for b in sorted(bs, key=lambda x: x["id"])]
        L.append("")
    L += ["## CONFIRMADO", "", ", ".join(sorted(b["id"] for b in beads if b["state"] == CONFIRMADO)) or "(nenhum)", ""]
    return "\n".join(L)


def load_state(path):
    """{id: iso} dos AINDA já avisados. Ausente = 1ª rodada. Ilegível = dito em voz alta e tratado como 1ª rodada."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            return dict(json.load(f)["notified"])
    except Exception as e:
        sys.stderr.write("daemon-unverified-sweep: estado ilegível em %s (%s: %s) — tratando como primeira rodada\n"
                         % (path, type(e).__name__, e))
        return {}


def save_state(path, notified, now):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"notified": notified, "last_run": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))},
                  f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def notify_text(new, counts, daemons, report_path):
    new_ids = sorted(b["id"] for b in new)
    top = {}
    for b in new:
        for label, (st, _w) in b["owner_states"].items():
            if st == AINDA:
                top[label] = top.get(label, 0) + 1
    top_s = ", ".join("%s (%d)" % kv for kv in sorted(top.items(), key=lambda kv: (-kv[1], kv[0]))[:3])
    head = "%d bead(s) novo(s) AINDA NÃO VISTO" % len(new_ids)
    if len(new_ids) <= 5:
        head += ": " + ", ".join(new_ids)
    return ("%s — código mergeado que o daemon dono ainda não recarregou. Daemons: %s. "
            "Total: %d ainda não visto · %d confirmado · %d não consegui saber. Relatório: %s"
            % (head, top_s or "?", counts[AINDA], counts[CONFIRMADO], counts[NCS], report_path))


def send_notify(title, text):
    try:
        r = run([env("DUS_NOTIFY", os.path.expanduser("~/.local/bin/notify")), "-t", title, "-p", "3", text], timeout=60)
    except (subprocess.TimeoutExpired, OSError) as e:
        sys.stderr.write("daemon-unverified-sweep: ERRO — notify não rodou (%s); baseline INTACTO, próxima rodada re-tenta.\n" % e)
        return False
    if r.returncode != 0:
        sys.stderr.write("daemon-unverified-sweep: ERRO — notify falhou (rc=%d); baseline INTACTO, próxima rodada re-tenta.\n"
                         % r.returncode)
        return False
    return True


def main(argv):
    ap = argparse.ArgumentParser(description="vigia semanal de delivery:daemon-unverified (detecta, não age)")
    ap.add_argument("--notify", action="store_true",
                    help="avisa (1 notificação) se há AINDA NÃO VISTO novo e grava o baseline; sem isto é dry-run: "
                         "escreve o relatório mas NÃO avisa e NÃO toca no baseline")
    args = ap.parse_args(argv)
    out_dir = env("DUS_OUT_DIR", os.path.join(CITY, ".gc", "logs"))
    os.makedirs(out_dir, exist_ok=True)
    # Instância única: a varredura é lenta (load alto) e uma 2ª rodada em cima da 1ª só dobra a carga no Dolt.
    lock = open(os.path.join(out_dir, "daemon-unverified-sweep.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("daemon-unverified-sweep: já em execução (lock em %s) — saindo sem varrer." % out_dir)
        return 0
    stores = load_stores()
    hq_store = env("DUS_HQ_STORE", stores[0]["store"] if stores else "")
    now = int(env("DUS_NOW", "0")) or int(time.time())
    deadline = time.monotonic() + float(env("DUS_DEADLINE", "2700"))
    plists, unreadable = load_plists()
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
            if b.get("status") != "closed":
                state, reason, owners, detail = OUT, "not-closed", [], {}
            elif time.monotonic() > deadline:
                state, reason, owners, detail = NCS, "deadline-exceeded", [], {}   # o que não deu tempo NÃO some: vira dúvida
            else:
                try:
                    state, reason, owners, detail = classify(b, hq_store, s["store"], s["repo"], now, plists, unreadable)
                except Exception as e:                                   # um bead estranho não derruba os outros
                    state, reason, owners, detail = NCS, "internal-error", [], {}
                    sys.stderr.write("daemon-unverified-sweep: bead %s: %s: %s\n" % (b.get("id"), type(e).__name__, e))
            beads.append({"id": b["id"], "rig": s["name"], "state": state, "reason": reason, "owners": owners,
                          "owner_states": detail})
    counts = {CONFIRMADO: 0, AINDA: 0, NCS: 0, OUT: 0}
    for b in beads:
        counts[b["state"]] += 1
    daemons = rollup(beads)
    with open(os.path.join(out_dir, "daemon-unverified-sweep-latest.json"), "w", encoding="utf-8") as f:
        json.dump({"counts": counts, "stores": store_status, "daemons": daemons, "beads": beads},
                  f, ensure_ascii=False, indent=1)
    report_path = os.path.join(out_dir, "daemon-unverified-sweep-%s.md" % time.strftime("%Y-%m-%d", time.localtime(now)))
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(render_md(now, counts, store_status, beads, daemons))
    broken = any(not v["ok"] for v in store_status.values()) or any(b["reason"] in READ_FAILED for b in beads)
    print("%s daemon-unverified-sweep: %s · relatório: %s" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        " · ".join("%s=%d" % (k, counts[k]) for k in (CONFIRMADO, AINDA, NCS, OUT)), report_path))

    if args.notify:
        state_path = os.path.join(out_dir, "daemon-unverified-sweep.state.json")
        notified = load_state(state_path)
        new = [b for b in beads if b["state"] == AINDA and b["id"] not in notified]
        delivered = True
        if new:
            delivered = send_notify("Vigia daemon-unverified", notify_text(new, counts, daemons, report_path))
            print("daemon-unverified-sweep: %d AINDA NÃO VISTO novo(s) — notificação %s."
                  % (len(new), "enviada" if delivered else "FALHOU"))
        if delivered:
            # NCS mantém a marca (voltar de uma leitura quebrada não é "novo"); só CONFIRMADO sai do baseline.
            confirmed = {b["id"] for b in beads if b["state"] == CONFIRMADO}
            keep = {i: t for i, t in notified.items() if i not in confirmed}
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
            keep.update({b["id"]: stamp for b in beads if b["state"] == AINDA and b["id"] not in keep})
            save_state(state_path, keep, now)
        else:
            broken = True
    return 3 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
