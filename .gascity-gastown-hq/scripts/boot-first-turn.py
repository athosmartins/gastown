#!/usr/bin/env python3
"""boot-first-turn.py (ga-esorlre.13, camada 1 da ga-esorlre.12): crew nomeada (e o Mayor) que acabou de subir e tem bead em andamento recebe UM 1º turno de verdade, digitado no pane.

POR QUE  Depois do reboot de 25-26/11 peter-wa e oracle-wa ficaram 6-8 h no prompt: o que chega a uma sessão ociosa por `gc session nudge` vira «deferred reminder» (só entra quando um turno começa).
  Só input digitado no pane acorda. Este job digita.
O QUE FAZ  A cada 60 s (launchd, RunAtLoad), lê as sessões do tmux da cidade (-L gascity). Alvo = sessão do Mayor ou de crew nomeada (agents/<crew>/agent.toml com work_dir .../crew/<slug>, slug != worker,
  max_active_sessions <= 1; o nome tmux é <crew>-gawisp<cauda>) criada há MIN_AGE_S..WINDOW_S (120 s a 20 min: o motor já terminou de digitar o prompt de partida e a sessão ainda é do boot).
  Para cada alvo: tem bead in_progress da sessão (assignee = nome tmux, alias ou incarnação anterior <alias>-gawisp..., lida no store da cidade e no do rig da crew) E o pane (capture-pane) é um
  prompt ocioso com a caixa VAZIA (sem «esc to interrupt», sem diálogo, sem rascunho)? Então digita UMA linha (send-keys -l; Enter em chamada separada) e grava (sessão, criada-em) no estado: uma vez por partida.
TRÊS ESTADOS  Leitura que não respondeu (tmux, bd, pane ilegível, arquivo de estado) nunca vira «ocioso» nem «sem trabalho»: não digita e conta em `nao-sei`. Digitação que falhou não é gravada como feita
  (tenta de novo no próximo passe e avisa o celular a cada passe que falhar, até a janela fechar). Sem trabalho = não digita (uma crew sem bead não ganha ordem; quem a acorda é a camada 2, ga-esorlre.14).
PROVA  Não está aqui: às 00:10 a camada 3 (ga-esorlre.15) confere que cada crew com bead em andamento se mexeu. Este job só garante que o 1º turno foi pedido (linha TYPED no log e no jsonl).
USO  boot-first-turn.py [--dry-run] (lê tudo, não digita nem grava). Desliga: BFT_ENABLED=0 ou .gc/boot-first-turn.off (arquivo ilegível = desligado).
  Saída 0 avaliou · 2 uso · 3 não consegui avaliar · 4 outra instância.  Regras e botões: docs/runbooks/boot-primeiro-turno.md.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

CITY_DEFAULT = "/Users/athos/gt/.gascity-gastown-hq"
MAYORS = ("gastown__mayor", "gastown.mayor", "mayor")
TAG = "[ga-esorlre.13 primeiro turno do boot]"
SAFE_ID = re.compile(r"[A-Za-z0-9._-]{1,48}")  # id de bead é digitado num terminal: nada além disto passa
DIALOG_RE = re.compile(r"Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel")
BUSY_RE = re.compile(r"esc to interrupt|…[^(\n]*\(\d+[hms]")
PLACEHOLDER_RE = re.compile(r'^Try ".*"$')  # sugestão apagada de conversa sem turno: não é rascunho
STATE_KEEP_S = 7 * 86400


def pane_state(text):
    """'idle' (prompt com caixa vazia) | 'working' | 'dialog' | 'draft' | 'unknown' (sem prompt do Claude à vista)."""
    lines = [x.rstrip() for x in text.splitlines() if x.strip()]
    if DIALOG_RE.search("\n".join(lines[-12:])):
        return "dialog"
    if BUSY_RE.search(text):
        return "working"
    prompt = next((x for x in reversed(lines) if x.lstrip().startswith("❯")), None)
    if prompt is None:
        return "unknown"
    draft = prompt.lstrip()[1:].strip()
    return "draft" if draft and not PLACEHOLDER_RE.match(draft) else "idle"


def compose(ids):
    """a linha digitada. ids vazio = nenhuma achada (a quem chama só chega aqui com ao menos uma)."""
    safe = [i for i in dict.fromkeys(ids) if SAFE_ID.fullmatch(i)][:5]
    return ("%s Sua sessão acabou de subir e ninguém vai te acordar: retome a bead em andamento %s e o último handoff; se não houver, pegue a próxima por prioridade. "
            "Siga até terminar; se travar, registre na bead (comentário e next-action) em vez de ficar parado." % (TAG, ", ".join(safe)))


def crews(agents_dir):
    """{nome do agente: work_dir} das crews nomeadas, ou None se agents/ não foi lido. Pasta sem agent.toml legível não é crew."""
    # vazio ({}): só o Mayor é alvo; falhou (None): quem chama conta nao-sei e segue só com o Mayor
    try:
        names = sorted(os.listdir(agents_dir))
    except OSError:
        return None
    out = {}
    for n in names:
        try:
            with open(os.path.join(agents_dir, n, "agent.toml"), encoding="utf-8") as fh:
                txt = fh.read()
        except (OSError, ValueError):
            continue
        wd = re.search(r'^work_dir\s*=\s*"([^"]*)"', txt, re.M)
        mx = re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        slug = re.search(r"/crew/([^/]+)$", wd.group(1)) if wd else None
        if slug and slug.group(1) != "worker" and not (mx and int(mx.group(1)) > 1):
            out[n] = wd.group(1)
    return out


def owns(name, alias, assignee):
    a = assignee.rstrip("/") if isinstance(assignee, str) else ""
    names = {name, alias} | ({"gastown.mayor", "mayor"} if alias in MAYORS else set())
    return bool(a) and (a in names or any(re.fullmatch(re.escape(n) + r"-gawisp[a-z0-9]+", a) for n in names))


class Job:
    def __init__(self, env, dry):
        g = env.get
        self.dry = dry
        self.city = g("GC_CITY_PATH") or CITY_DEFAULT
        self.tmux = [g("BFT_TMUX") or "tmux", "-L", g("BFT_TMUX_SOCKET") or "gascity"]
        self.bd = g("BFT_BD") or "bd"
        self.notify = g("BFT_NOTIFY") or "notify"
        self.min_age, self.window = int(g("BFT_MIN_AGE_S") or 120), int(g("BFT_WINDOW_S") or 1200)
        self.timeout = int(g("BFT_TIMEOUT_S") or 20)
        gc_dir = os.path.join(self.city, ".gc")
        self.state_path, self.lock_path = os.path.join(gc_dir, "boot-first-turn.state.json"), os.path.join(gc_dir, "boot-first-turn.lock")
        self.off_path = os.path.join(gc_dir, "boot-first-turn.off")
        self.log_path, self.jsonl_path = os.path.join(gc_dir, "logs", "boot-first-turn.log"), os.path.join(gc_dir, "logs", "boot-first-turn.jsonl")
        self.enabled = g("BFT_ENABLED", "1") != "0"
        self.stores = {}

    def run(self, argv):
        """(rc, stdout); rc None = não rodou ou estourou o prazo: nunca uma resposta vazia."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=self.timeout)
        except (OSError, subprocess.SubprocessError):
            return None, ""
        return p.returncode, p.stdout

    def say(self, path, line):
        # falhou (pasta ausente, disco cheio) → aviso no stderr e segue: o log não é condição para digitar
        if self.dry and path == self.log_path:
            print(line)
        elif not self.dry:
            try:
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except OSError as ex:
                sys.stderr.write("WARN: cannot append to %s: %s\n" % (path, ex))

    def log(self, msg):
        self.say(self.log_path, "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))

    def sessions(self):
        """[(nome tmux, criada em epoch)] ou None. vazio (nenhuma sessão): []; falhou (tmux sem servidor, estouro, linha ruim): None, nunca []."""
        rc, out = self.run(self.tmux + ["list-sessions", "-F", "#{session_name}\t#{session_created}"])
        if rc != 0:
            return None
        rows = []
        for ln in out.splitlines():
            n, _, c = ln.partition("\t")
            if not n or not c.isdigit():
                return None
            rows.append((n, int(c)))
        return rows

    def in_progress(self, store):
        """ids→assignee das beads em andamento de um store (lido UMA vez por passe) ou None. vazio: []; falhou/ilegível: None, e a linha nunca afirma «não há»."""
        if store not in self.stores:
            rc, out = self.run([self.bd, "-C", store, "list", "--status", "in_progress", "--json", "--limit", "0"])
            got = None
            if rc == 0:
                try:
                    j = json.loads(out)
                except ValueError:
                    j = None
                got = [b for b in j if isinstance(b, dict) and isinstance(b.get("id"), str)] if isinstance(j, list) else None
            self.stores[store] = got
        return self.stores[store]

    def work_of(self, name, alias, work_dir):
        """(ids, lidos_todos): ids das beads em andamento da sessão; lidos_todos False se algum store não respondeu."""
        stores = [self.city]
        rig = re.fullmatch(r"(.+)/crew/[^/]+", work_dir or "")
        if rig and rig.group(1) != self.city:
            stores.append(rig.group(1))
        ids, ok = [], True
        for s in stores:
            got = self.in_progress(s)
            if got is None:
                ok = False
                continue
            ids += [b["id"] for b in got if owns(name, alias, b.get("assignee"))]
        return sorted(set(ids)), ok

    def pane(self, name):
        """texto do pane ou None (não leu)."""
        rc, out = self.run(self.tmux + ["capture-pane", "-p", "-t", "=%s:" % name, "-S", "-40"])
        return out if rc == 0 else None

    def type_line(self, name, text):
        """True se o texto foi digitado (Enter que falhou deixa a linha na caixa: ERROR no log, conta como feita)."""
        rc, _ = self.run(self.tmux + ["send-keys", "-t", "=%s:" % name, "-l", text])
        if rc != 0:
            return False
        time.sleep(1.0)
        rc, _ = self.run(self.tmux + ["send-keys", "-t", "=%s:" % name, "Enter"])
        if rc != 0:
            self.log("ERROR %s: o texto foi digitado mas o Enter falhou: a linha espera na caixa de entrada" % name)
        return True

    def alarm(self, msg):
        self.log("ALARM " + msg)
        if not self.dry:
            self.run([self.notify, "-p", "4", "-t", "Boot: 1º turno não digitado", msg])


def load_state(path):
    # vazio (arquivo ausente) → {}; ilegível (JSON ruim, formato errado) → {}: o pior caso é UMA linha a mais numa sessão ainda na janela
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in d.items() if isinstance(v, (int, float)) and not isinstance(v, bool)} if isinstance(d, dict) else {}


def run_pass(job):
    """→ (exit, contagens). Sessão vista = (nome, criada): a mesma chave só é servida uma vez."""
    c = dict.fromkeys(("alvos", "digitou", "feito", "sem-trabalho", "espera", "nao-sei", "tarde"), 0)
    now = time.time()
    rows = job.sessions()
    if rows is None:
        job.log("ERROR: não consegui avaliar, nada digitado: tmux list-sessions não respondeu")
        return 3, c
    young = [(n, t) for n, t in rows if job.min_age <= now - t <= job.window]
    c["tarde"] = sum(1 for _, t in rows if now - t > job.window)
    if not young:
        return 0, c  # estado de regime (todas as sessões com dias): nenhuma chamada a bd/gc/tmux além da lista
    known = crews(os.path.join(job.city, "agents"))
    if known is None:
        job.log("WARN: agents/ ilegível: só o Mayor é alvo neste passe")
    state = load_state(job.state_path)
    dirty = False
    for name, created in sorted(young):
        alias = name if name in MAYORS else re.sub(r"-gawisp[a-z0-9]+$", "", name)
        if alias not in MAYORS and alias not in (known or {}):
            continue
        c["alvos"] += 1
        key = "%s@%d" % (name, created)
        if key in state:
            c["feito"] += 1
            continue
        ids, all_read = job.work_of(name, alias, (known or {}).get(alias))
        if not ids:
            if all_read:
                c["sem-trabalho"] += 1
            else:
                c["nao-sei"] += 1
                job.log("UNKNOWN %s: um store de beads não respondeu: não digito às cegas" % name)
            continue
        text = job.pane(name)
        st = pane_state(text) if text is not None else "unknown"
        if st != "idle":
            c["nao-sei" if st == "unknown" else "espera"] += 1
            job.log("%s %s: pane %s; beads em andamento: %s" % ("UNKNOWN" if st == "unknown" else "WAIT", name, st, ", ".join(ids)))
            continue
        if job.dry:
            job.log("WOULD type %s (beads %s): %s" % (name, ", ".join(ids), compose(ids)))
            c["digitou"] += 1
            continue
        if not job.type_line(name, compose(ids)):
            c["nao-sei"] += 1
            job.alarm("a linha de 1º turno NÃO foi digitada em %s (tmux send-keys falhou); tenta de novo no próximo passe" % name)
            continue
        state[key] = now
        dirty = True
        c["digitou"] += 1
        job.log("TYPED %s: o 1º turno, beads em andamento: %s" % (name, ", ".join(ids)))
        job.say(job.jsonl_path, json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "target": name, "created": created, "ids": ids, "result": "typed"}, ensure_ascii=False, sort_keys=True))
    state = {k: v for k, v in state.items() if now - v <= STATE_KEEP_S}
    if dirty and not job.dry:
        tmp = "%s.tmp%d" % (job.state_path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(state, fh, sort_keys=True)
            os.replace(tmp, job.state_path)
        except OSError as ex:
            job.log("WARN: cannot save %s: %s: o próximo passe pode digitar uma vez a mais (inofensivo)" % (job.state_path, ex))
    return 0, c


def is_off(job):
    # vazio (sem o arquivo .off) → ligado; ilegível (permissão, laço de symlink, EIO) → desligado: os.path.exists leria como «ausente» e digitaria
    if not job.enabled:
        return True
    try:
        os.stat(job.off_path)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def main(argv=None, env=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv not in ([], ["--dry-run"]):
        sys.stderr.write("usage: boot-first-turn.py [--dry-run]\n")
        return 2
    job, tag = Job(os.environ if env is None else env, argv == ["--dry-run"]), "boot-first-turn:"
    if is_off(job):
        print("%s desligado (BFT_ENABLED=0 ou .gc/boot-first-turn.off)" % tag)
        return 0
    try:
        fh = open(job.lock_path, "a")
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("%s outra instância em curso" % tag)
        return 4
    except OSError as ex:
        print("%s NÃO consegui a trava %s: %s" % (tag, job.lock_path, ex))
        return 3
    try:
        code, c = run_pass(job)
    finally:
        fh.close()
    if code != 0:
        print("%s NÃO consegui avaliar (ver %s)" % (tag, job.log_path))
        return code
    print("%s %s%s" % (tag, " ".join("%s=%d" % kv for kv in c.items()), " (dry-run)" if job.dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
