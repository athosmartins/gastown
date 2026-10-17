#!/usr/bin/env python3
"""daemon-unverified-sweep.py — vigia de `delivery:daemon-unverified` (ga-iyfe83, parte 3 da ga-29ssni). FATIAS 1-2: núcleo + sha/dono/periódico.

O PROBLEMA. O gate fecha um bead com o rótulo `delivery:daemon-unverified` quando o código mergeado pode estar
DORMENTE: o daemon que o executa não foi (ou não pôde ser) confirmado reiniciado depois do merge. ~300 beads
carregam o rótulo e NADA o lia — o rótulo era um lembrete que ninguém consultava.

O QUE ESTE VIGIA FAZ. Para cada bead fechado com o rótulo decide EXATAMENTE UM de três estados, que nunca colapsam:

  CONFIRMADO          o daemon dono do código mergeado subiu DEPOIS do merge (início do processo vivo > merge).
  AINDA NÃO VISTO     subiu ANTES do merge, ou o daemon não está carregado.
  NÃO CONSEGUI SABER  sem sha de merge, sem daemon identificável, sem processo pra ler o início, ou a leitura falhou.
                      (daemon periódico: CONFIRMADO se um ciclo inteiro passou depois do merge, AINDA se ainda não passou.)

Regra de ouro (E12: "vazio ≠ falhou"): NÃO CONSEGUI SABER é o estado de qualquer dúvida. Leitura que falhou
(bd/launchctl/ps/git, timeout, saída ilegível) NUNCA vira CONFIRMADO — e também não vira "AINDA NÃO VISTO" nem
"nenhum daemon": é NÃO CONSEGUI SABER, com o motivo (`reason`) dizendo qual leitura quebrou.
Precedência quando um bead tem vários daemons donos: AINDA NÃO VISTO > NÃO CONSEGUI SABER > CONFIRMADO
(um dono sem reinício já basta pra o código estar dormente; CONFIRMADO exige TODOS os donos confirmados).

DETECTA, NÃO AGE. Não reinicia nada e não roda daemon-refresh: o Mayor / dono do daemon decide a partir do relatório.
As únicas chamadas ao launchd são `launchctl list <label>` (leitura).

Motivos (`reason`):
  CONFIRMADO:  started-after-merge · period-elapsed
  AINDA:       started-before-merge · not-loaded · period-not-elapsed
  NCS (conteúdo, rc 0):        no-merge-sha · no-daemon · sha-not-on-disk · sha-not-in-checkout · event-driven ·
                               unknown-kind · loaded-no-pid · duplicate-label
  NCS (leitura quebrou, rc 3): marker-read-failed · deps-read-failed · launchctl-read-failed · ps-read-failed ·
                               git-read-failed · bad-timestamp · plist-read-failed · status-unknown · internal-error
  Uma LOJA que não listou não é uma loja com zero beads: fica em `stores` (ok=false) no relatório e o rc é 3.

COMO ACHA O SHA E O DONO (fatia 2; o que não se acha é NÃO CONSEGUI SABER com motivo, nunca CONFIRMADO):
  - sha do merge: `sha=<40hex>` do `close_reason` do bead; sem ele, o marcador de gate PASSED do bead (label
    `source-bead:<id>`, loja HQ). Os marcadores vêm numa consulta em lote só por execução, indexada em memória
    (a consulta por bead passou de 45 min com o load em ~60; a em lote leva segundos). A consulta que falha é
    `marker-read-failed`, nunca "sem marcador" (= no-merge-sha). Marcador com data ilegível é bad-timestamp.
  - dono: o plist que roda exatamente um arquivo da entrega (ProgramArguments) OU o daemon cujo closure/assets em
    `daemons/deploy_deps.json` inclui o arquivo (lib importada). O mapa é lido no commit do merge E no HEAD vivo
    (união): o daemon que importava o arquivo quando ele entrou e o que o importa hoje são ambos donos.
  - tipo do daemon: KeepAlive (início do processo vivo × merge) · periódico = StartInterval / StartCalendarInterval
    (cada disparo é um processo novo; um ciclo inteiro depois do merge basta) · WatchPaths / QueueDirectories /
    sem gatilho conhecido = NCS (nada prova que um evento rodou depois do merge).
  - dry-run: escreve `daemon-unverified-sweep-latest.json` e imprime as contagens. (.3: relatório legível, aviso, plist.)

LIMITES CONHECIDOS (o relatório é uma triagem, não uma prova):
  - "subiu depois do merge" é NECESSÁRIO, não SUFICIENTE: se o checkout vivo só recebeu o código depois do merge
    (pull atrasado), um daemon que subiu entre o merge e o pull sai CONFIRMADO sem ter rodado o código novo.
  - Periódico: "um ciclo inteiro passou" conta o relógio, não o tempo acordado; a máquina dormir no intervalo atrasa
    o disparo e o veredito CONFIRMADO pode sair cedo. Interesse de triagem, não de prova.
  - O mapa deploy_deps.json só existe no rig WhatsApp; nos outros, ausente = "sem mapa" (≠ ilegível = deps-read-failed).
  - Os marcadores só são procurados na loja HQ (onde o gate grava os de todos os rigs): marcador guardado só na
    loja do rig não é visto (no-merge-sha, NCS — nunca CONFIRMADO).
  - O sha do merge é só a PONTA da branch. Numa entrega em fast-forward com vários commits, os arquivos dos
    commits anteriores só entram na conta porque o script TAMBÉM busca commits cujo ASSUNTO cita o id do bead como
    token inteiro (janela de 30 dias antes do merge). Commit que não cita o bead no assunto e não é a ponta não é visto.
  - O dono é achado pelo caminho ABSOLUTO do arquivo em `ProgramArguments`. Plist que roda o arquivo por `Program`, ou
    dentro de `bash -c "…"`, não é visto como dono (hoje: com.athos.verify-pessoas-ref-fix tem `Program` e nenhum
    `ProgramArguments`; o único KeepAlive com `-c` é o dolt-server).
  - KeepAlive que roda até terminar (ex.: voicebot-campaign-run) fica sem PID entre execuções: sem processo não se lê o
    início (NCS loaded-no-pid). O mesmo bead pode oscilar CONFIRMADO ↔ NCS conforme o instante da varredura.
  - O repo do sha é o do checkout da loja que listou o bead: sha de outro rig sai sha-not-on-disk (NCS), nunca CONFIRMADO.

COMO RODA. Dry-run: escreve `daemon-unverified-sweep-latest.json` em .gc/logs e imprime uma linha com as contagens por estado.
Saída: 0 = leu tudo · 3 = alguma leitura falhou (ver `stores` / `reason` no JSON).
Sementes de teste: DUS_BD, DUS_LAUNCHCTL, DUS_PS, DUS_STORES, DUS_OUT_DIR, DUS_NOW…
A loja HQ é a PRIMEIRA de DUS_STORES (os marcadores de gate de todos os rigs moram nela).
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
READ_FAILED = {"marker-read-failed", "deps-read-failed", "launchctl-read-failed", "ps-read-failed", "git-read-failed",
               "bad-timestamp", "plist-read-failed", "internal-error", "status-unknown"}

DEPS_PATH = "daemons/deploy_deps.json"      # mapa daemon → closure/assets (só o rig WhatsApp tem)


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
    return subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="surrogateescape", env=e,
                          timeout=timeout if timeout is not None else int(env("DUS_CMD_TIMEOUT", "60")))


def read(cmd, reason):
    """Uma leitura externa. Timeout / binário que não abre → ReadFailed(reason): resposta que faltou ≠ resposta vazia."""
    try:
        return run(cmd)
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ReadFailed(reason, str(e))


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


def bd_list(store, labels, infra=False):
    """`bd -C <store> list --label … --all --json --limit 0` com retry. Falha sustentada → ReadFailed('bd-failed').

    A máquina vive com load ~70 e o Dolt estoura timeout de leitura (`i/o timeout`, `invalid connection`): UMA
    falha não pode virar "loja sem beads" — por isso retry, e depois de esgotar, ReadFailed (≠ lista vazia).
    `infra`: o bd 1.1.0 omite bead efêmero (INFRA) do `list` por padrão; marcador de gate antigo é efêmero."""
    cmd = [env("DUS_BD", "bd"), "-C", store, "list"]
    for l in labels:
        cmd += ["--label", l]
    cmd += ["--all", "--json", "--limit", "0"] + (["--include-infra"] if infra else [])
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


class Markers:
    """Os marcadores de gate PASSED, lidos UMA vez por execução (e só se algum bead precisar) e indexados por bead.

    A consulta por bead não terminou em 45 min com o load em ~60 (170 de 314 estouraram o prazo); a em lote leva segundos.
    Consulta que falhou fica guardada como falha (`error`) e TODO bead que depender dela sai marker-read-failed: a falha
    não vira "bead sem marcador"."""

    def __init__(self, store):
        self.store, self.by_bead, self.error, self.seconds, self.n = store, None, None, 0.0, 0

    def rows(self, bead_id):
        if self.by_bead is None and self.error is None:
            t0 = time.monotonic()
            try:
                rows = bd_list(self.store, ["type:quality-gate-marker", "gate-status:passed"], infra=True)
                idx = {}                                  # só vira o índice se TODAS as linhas lerem (nunca um índice pela metade)
                for m in rows:
                    labels = m.get("labels")
                    for l in (labels if isinstance(labels, list) else []):
                        if isinstance(l, str) and l.startswith("source-bead:"):
                            idx.setdefault(l[len("source-bead:"):], []).append(m)
                self.by_bead, self.n = idx, len(rows)
            except ReadFailed as e:
                self.error = e.detail or e.reason
            except (AttributeError, TypeError) as e:       # linha que não é objeto JSON
                self.error = "marcador ilegível: %s: %s" % (type(e).__name__, e)
            self.seconds = round(time.monotonic() - t0, 1)
        if self.error is not None:
            raise ReadFailed("marker-read-failed", self.error)
        return self.by_bead.get(bead_id, [])          # leu e o bead não tem marcador: lista vazia (≠ falha, que levanta acima)

    def status(self):
        if self.by_bead is None and self.error is None:
            return {"read": False}
        return {"read": True, "ok": self.error is None, "error": self.error or "", "n": self.n, "seconds": self.seconds}


def marker_merge(rows):
    """(sha, quando, 'marker') do marcador PASSED mais recente que traz `sha=`; nenhum com sha → None.
    Marcador com sha e data ilegível NÃO é descartado: o ilegível pode ser o re-merge mais novo, e julgar pelo antigo daria
    CONFIRMADO falso. Ilegível → bad-timestamp (a leitura quebrou), mesmo que outro marcador esteja legível."""
    found, bad = [], None
    for m in rows:
        sha = SHA_RE.search(m.get("close_reason") or "")
        if not sha:
            continue
        try:
            found.append((ts(m.get("closed_at")), sha.group(1)))
        except ReadFailed as e:
            bad = e
    if bad:
        raise bad
    if found:
        t, sha = max(found)                       # o último desembarque vence (re-merge)
        return sha, t, "marker"
    return None


def merge_of(bead, markers):
    """O sha mergeado e QUANDO desembarcou. 1º o `close_reason` do bead (`sha=<40hex>`; tempo = closed_at do bead, que é >=
    o merge: erra pro lado conservador). Sem sha ali → o marcador de gate PASSED do bead. Sem nenhum → None (NÃO CONSEGUI
    SABER: no-merge-sha). Marcador que não se conseguiu ler levanta ReadFailed — nunca é o mesmo que "sem marcador".
    Sha sem `closed_at` não é "sem sha": o sha existe e o QUANDO faltou → ts() levanta bad-timestamp (leitura que falhou)."""
    m = SHA_RE.search(bead.get("close_reason") or "")
    if m:
        return m.group(1), ts(bead.get("closed_at")), "close_reason"
    return marker_merge(markers.rows(bead["id"]))


def sha_place(repo, sha):
    """'in-checkout' | 'not-in-checkout' (o sha existe no repo mas não é ancestral do HEAD vivo: pull atrasado) |
    'not-on-disk'. `cat-file -e` dá 128 pra sha ausente E pra repo quebrado; `rev-parse --verify --quiet` dá 1 só pro
    ausente. Repo quebrado é leitura que falhou (git-read-failed), não "sha fora do disco"."""
    c = read(["git", "-C", repo, "rev-parse", "--verify", "--quiet", sha + "^{commit}"], "git-read-failed")
    if c.returncode == 1:
        return "not-on-disk"
    if c.returncode != 0:
        raise ReadFailed("git-read-failed", c.stderr.strip()[-200:] or "rev-parse rc=%d" % c.returncode)
    a = read(["git", "-C", repo, "merge-base", "--is-ancestor", sha, "HEAD"], "git-read-failed")
    if a.returncode in (0, 1):
        return "in-checkout" if a.returncode == 0 else "not-in-checkout"
    raise ReadFailed("git-read-failed", a.stderr.strip()[-200:])


def git(repo, *args):
    """stdout do git; rc != 0 → ReadFailed (git que falhou ≠ saída vazia = "nenhum arquivo / nenhum commit")."""
    r = read(["git", "-C", repo, *args], "git-read-failed")
    if r.returncode != 0:
        raise ReadFailed("git-read-failed", r.stderr.strip()[-200:])
    return r.stdout


def changed_files(repo, sha):
    out = git(repo, "diff-tree", "-r", "--name-only", "-z", "--no-commit-id", "-m", "--first-parent", sha)
    return [x for x in out.split("\0") if x]            # -z: nome com acento / tab não vem entre aspas


def delivery_files(repo, sha, bead_id, merged_at):
    """Arquivos da ENTREGA: os da ponta (`sha`) + os dos outros commits do bead.

    O gate mergeia em fast-forward: `sha` é só a PONTA da branch, e olhar só o diff dela perde os donos dos commits
    anteriores — o erro perigoso (falso CONFIRMADO). Commit do bead = o ASSUNTO cita o id como token inteiro
    (`ga-x1` ≠ `ga-x11` ≠ o filho `ga-x1.2`); menção no corpo de commit de OUTRO bead não vale. O casamento tem que
    ser exato porque os arquivos a mais podem dar dono (e veredito) a um bead cuja ponta só tocou doc ou teste."""
    files = set(changed_files(repo, sha))
    log = git(repo, "log", "--fixed-strings", "--grep=" + bead_id, "--format=%H %s", "--since=%d" % (merged_at - BRANCH_WINDOW), sha)
    cites = re.compile(r"(?<![\w-])%s(?![\w-]|\.\d)" % re.escape(bead_id))
    for line in log.split("\n"):
        c, _, subject = line.partition(" ")
        if c != sha and cites.search(subject):
            files |= set(changed_files(repo, c))
    return sorted(files)


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
    """({label: [plist, …]}, {"unreadable", "no_label", "via_plutil": [arquivos]}). Plist que não lê NÃO some em silêncio:
    vira dúvida (plist-read-failed). Plist lido mas sem Label não é daemon (o launchd não o carrega): fica listado à
    parte. Dois arquivos com o mesmo Label ficam os dois (o launchd carrega um só). Nenhum *.plist (pasta que não existe
    ou não abre) é leitura que falhou, não "nenhum daemon": ReadFailed."""
    plists, info = {}, {"unreadable": [], "no_label": [], "via_plutil": []}
    files = sorted(glob.glob(os.path.join(env("DUS_LAUNCH_AGENTS_DIR", os.path.join(HOME, "Library", "LaunchAgents")), "*.plist")))
    if not files:
        raise ReadFailed("plist-read-failed", "nenhum *.plist em DUS_LAUNCH_AGENTS_DIR / ~/Library/LaunchAgents")
    for p in files:
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
            plists.setdefault(label, []).append(pl)
        else:
            info["no_label"].append(name)
    return plists, info


_deps_cache = {}


def deps_at(repo, rev):
    """{arquivo: {labels}} do `daemons/deploy_deps.json` (closure + assets de cada daemon) em `rev` (um sha ou HEAD).

    Três respostas que não se confundem: o rig não tem o mapa em `rev` → {} (ls-tree rc 0, sem saída); tem e não leu →
    ReadFailed('deps-read-failed'); tem e leu → o mapa. `ls-tree` separa "ausente" de "git quebrado" (o `cat-file -e` dá
    128 pros dois). Lê do git, não do disco: edição não commitada no checkout não é o código mergeado."""
    key = (repo, rev)
    if key not in _deps_cache:
        try:
            tree = git(repo, "ls-tree", "--name-only", rev, "--", DEPS_PATH)
            out = {}
            if tree.strip():
                for d in json.loads(git(repo, "show", "%s:%s" % (rev, DEPS_PATH)))["daemons"].values():
                    closure, assets = d["closure"], d.get("assets", [])     # closure sempre existe; assets só em alguns daemons
                    if not isinstance(closure, list) or not isinstance(assets, list):
                        raise ValueError("closure/assets não é lista")      # string viraria "uma lib por letra": dono errado, calado
                    for rel in closure + assets:
                        out.setdefault(rel, set()).add(d["label"])
            _deps_cache[key] = out
        except ReadFailed as e:
            raise ReadFailed("deps-read-failed", e.detail or e.reason)
        except (ValueError, KeyError, TypeError, AttributeError) as e:      # JSON quebrado / formato que não é o esperado
            raise ReadFailed("deps-read-failed", "%s: %s" % (type(e).__name__, e))
    return _deps_cache[key]


def owners_of(files, repo, plists, deps):
    """Labels dos daemons donos dos `files`: (a) o plist roda exatamente esse arquivo (ProgramArguments); (b) o arquivo está
    no closure/assets do daemon em `deps` (lib importada). Label do mapa SEM plist nesta máquina não é dono: não roda aqui."""
    real = os.path.realpath(repo)
    fileset = set(files)
    labels = set()
    for label, pls in plists.items():
        for pl in pls:
            progs = {os.path.relpath(os.path.realpath(a), real) for a in pl.get("ProgramArguments", []) if a.startswith("/")}
            if progs & fileset:
                labels.add(label)
    for f in files:
        labels |= {l for l in deps.get(f, ()) if l in plists}
    return sorted(labels)


def launchctl_pid(label):
    """('not-loaded', None) | ('loaded', pid|None). Erro de leitura → ReadFailed (≠ not-loaded)."""
    r = read([env("DUS_LAUNCHCTL", "launchctl"), "list", label], "launchctl-read-failed")
    if r.returncode == 0 and '"Label"' in r.stdout:
        m = re.search(r'"PID"\s*=\s*(\d+);', r.stdout)
        return "loaded", (m.group(1) if m else None)
    if "Could not find service" in (r.stderr + r.stdout):
        return "not-loaded", None
    raise ReadFailed("launchctl-read-failed", (r.stderr or r.stdout).strip()[-200:])


def process_start(pid):
    r = read([env("DUS_PS", "ps"), "-o", "lstart=", "-p", pid], "ps-read-failed")
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        raise ReadFailed("ps-read-failed", "ps rc=%d, sem saída (processo sumiu?)" % r.returncode)
    try:
        return int(time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y")))
    except ValueError:
        raise ReadFailed("ps-read-failed", "lstart ilegível: %r" % out)


def cal_period(entry):
    """Maior vão possível entre dois disparos de UMA entrada de StartCalendarInterval (conservador: erra pra mais)."""
    if not isinstance(entry, dict):
        raise ReadFailed("plist-read-failed", "StartCalendarInterval ilegível: %r" % (entry,))
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


def period_seconds(plist):
    """Tempo depois do qual PELO MENOS um disparo já ocorreu: o menor dos vãos (vários gatilhos só encurtam o maior vão).
    Valor que não é número positivo não vira período: StartInterval=0 daria 'sempre decorrido' = CONFIRMADO falso."""
    periods = []
    if "StartInterval" in plist:
        v = plist["StartInterval"]
        if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
            raise ReadFailed("plist-read-failed", "StartInterval ilegível: %r" % (v,))
        periods.append(v)
    cal = plist.get("StartCalendarInterval")
    if cal is not None:
        periods += [cal_period(e) for e in (cal if isinstance(cal, list) else [cal])]
    if not periods:                                      # lista vazia de StartCalendarInterval: o launchd não dispara nunca
        raise ReadFailed("plist-read-failed", "StartCalendarInterval vazio")
    return min(periods)


def owner_state(pls, merged_at, now):
    plist = pls[0]
    status, pid = launchctl_pid(plist["Label"])
    if status == "not-loaded":
        return AINDA, "not-loaded"
    if len(pls) > 1:
        return NCS, "duplicate-label"       # dois arquivos com o mesmo Label: o launchd carrega um só, e qual eu não sei
    if not plist.get("KeepAlive"):
        if "StartInterval" in plist or "StartCalendarInterval" in plist:
            # periódico: cada disparo é um processo novo que lê o código do disco (o sha já está no checkout vivo). Passou um
            # ciclo inteiro desde o merge → algum disparo rodou o código novo; senão, ainda pode não ter rodado.
            if now - merged_at >= period_seconds(plist):
                return CONFIRMADO, "period-elapsed"
            return AINDA, "period-not-elapsed"
        if plist.get("WatchPaths") or plist.get("QueueDirectories"):
            return NCS, "event-driven"      # sem período: nada prova que algum evento disparou depois do merge
        return NCS, "unknown-kind"
    if pid is None:
        return NCS, "loaded-no-pid"         # carregado e sem processo: não há início pra ler (≠ "subiu antes do merge")
    started = process_start(pid)
    if started > merged_at:
        return CONFIRMADO, "started-after-merge"
    return AINDA, "started-before-merge"


def classify(bead, repo, plists, unreadable, markers, now):
    try:
        got = merge_of(bead, markers)
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    if not got:
        return NCS, "no-merge-sha", [], {}
    sha, merged_at, _src = got
    try:
        place = sha_place(repo, sha)
        if place != "in-checkout":
            return NCS, "sha-" + place, [], {}
        files = delivery_files(repo, sha, bead["id"], merged_at)
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    try:
        # o mapa do commit do merge E o do HEAD vivo: o daemon que importava o arquivo quando ele entrou e o que o importa
        # hoje são ambos donos (um dono a mais nunca melhora o veredito dos que já havia: CONFIRMADO exige todos).
        deps = {}
        for rev in (sha, "HEAD"):
            for rel, labels in deps_at(repo, rev).items():
                deps.setdefault(rel, set()).update(labels)
    except ReadFailed as e:
        return NCS, e.reason, [], {}
    owners = owners_of(files, repo, plists, deps)
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


def main(argv):
    ap = argparse.ArgumentParser(description="vigia de delivery:daemon-unverified (detecta, não age)")
    ap.parse_args(argv)
    out_dir = env("DUS_OUT_DIR", os.path.join(CITY, ".gc", "logs"))
    os.makedirs(out_dir, exist_ok=True)
    stores = load_stores()
    now = int(env("DUS_NOW", "0")) or int(time.time())
    try:
        plists, pinfo = load_plists()
    except ReadFailed as e:                   # sem LaunchAgents lido, "nenhum daemon é dono" não é uma resposta
        plists, pinfo = None, {"unreadable": [], "no_label": [], "via_plutil": [], "error": e.detail}
        sys.stderr.write("daemon-unverified-sweep: ERRO — não consegui ler os plists (%s)\n" % e.detail)
    unreadable = pinfo["unreadable"]
    markers = Markers(stores[0]["store"])         # HQ é a primeira loja: os marcadores de TODOS os rigs moram lá
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
            elif plists is None:
                state, reason, owners, detail = NCS, "plist-read-failed", [], {}
            else:
                try:
                    state, reason, owners, detail = classify(b, s["repo"], plists, unreadable, markers, now)
                except Exception as e:                                   # um bead estranho não derruba os outros
                    state, reason, owners, detail = NCS, "internal-error", [], {}
                    sys.stderr.write("daemon-unverified-sweep: bead %s: %s: %s\n" % (b.get("id"), type(e).__name__, e))
            beads.append({"id": b["id"], "rig": s["name"], "state": state, "reason": reason, "owners": owners,
                          "owner_states": detail})
    counts = {CONFIRMADO: 0, AINDA: 0, NCS: 0, OUT: 0}
    for b in beads:
        counts[b["state"]] += 1
    report_path = os.path.join(out_dir, "daemon-unverified-sweep-latest.json")
    with open(report_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "counts": counts,
                   "stores": store_status, "markers": markers.status(), "plists": dict(pinfo, n=len(plists or {})),
                   "beads": beads},
                  f, ensure_ascii=False, indent=1)
    os.replace(report_path + ".tmp", report_path)          # quem lê (a .3) nunca vê um JSON pela metade
    reasons = {b["reason"] for b in beads} | {v[1] for b in beads for v in b["owner_states"].values()}
    broken = plists is None or any(not v["ok"] for v in store_status.values()) or bool(reasons & READ_FAILED)   # falha de dono conta mesmo sob AINDA
    mk = markers.status()
    mk_line = "" if not mk["read"] else (" · marcadores: n=%d em %.1fs" % (mk["n"], mk["seconds"]) if mk["ok"]
                                         else " · marcadores: FALHOU (%s)" % mk["error"])
    print("%s daemon-unverified-sweep: %s%s · relatório: %s" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        " · ".join("%s=%d" % (k, counts[k]) for k in (CONFIRMADO, AINDA, NCS, OUT)), mk_line, report_path))
    return 3 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
