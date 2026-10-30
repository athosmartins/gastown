#!/usr/bin/env python3
"""hetzner-ballast.py — o lastro do nó Hetzner: trabalho útil de baixa prioridade que ocupa a CPU que sobra e cede na hora. (ga-2hd02v.5) Python 3.9+, só biblioteca padrão.

Contents
  Para que serve · Roda ONDE · O contrato do nice · Teto de sistema por item · Um tick · Itens · Três estados · Arquivos · Uso

PARA QUE SERVE
  Athos (20/10): "se está 100% ocupado a gente fica feliz; o que não pode é ficar menos". Mesmo com toda bead elegível indo ao nó, a fila tem buracos (madrugada de 20/10: 7 h em 0-15% de CPU).
  Este governo roda NO NÓ (cron do `runner`, a cada minuto) e, quando a CPU livre passa de 15% por 3 leituras seguidas, começa o próximo item da fila de lastro (hetzner-ballast.items.txt, no nó items.tsv).
RODA ONDE
  No nó, como `runner`, sem root e sem rede para o mini: um tick só lê /proc e arquivos da própria pasta. A instalação, a chave de ligar e o resultado são do mini (hetzner-ballast.sh).
O CONTRATO DO NICE
  Todo item roda em nice 19 + SCHED_IDLE (chrt -i 0) + ionice classe 3: o escalonador entrega a CPU a qualquer sessão (nice 0) na hora, sem esperar este governo. O /proc/stat conta esse tempo
  na coluna `nice`, e é por isso que ele NÃO é carga: carga = user+system+irq+softirq+steal (nice <= 0). O hetzner-capacity.py lê a mesma coluna (CPU em nice > 0 é folga da cidade) — sem isso o
  lastro faria o nó parecer "quente" e a cidade deixaria de mandar bead para ele.
TETO DE SISTEMA POR ITEM  (ga-kgnjkt8; runbook: "Teto de sistema por item")
  O nice 19 protege a CPU, não a tabela de processos nem a RAM, e o governo só olha a RAM uma vez por minuto e só enxerga a SESSÃO do item. Por isso cada item entra num escopo systemd do usuário
  (ballast.slice/ballast-<rodada>.scope) com TasksMax e MemoryMax (rss_mb x fator). O tick lê pids.events (fork recusado) e memory.events (oom_kill) do cgroup do item e o mata de imediato
  (teto-processos / teto-memoria); o fim de rodada e o stop mandam cgroup.kill, que pega também quem fez setsid. Contador ilegível ou caminho que não é o escopo DESTA rodada nunca vira 'zero estouros'
  nem alcança outro cgroup. Sem o gerenciador de usuário do systemd (sem sessão aberta e sem linger) o item NÃO começa: nota sem-teto no tick, motivo no stderr.
UM TICK  (exit 0 sempre que "não consegui ler" — vira nota no registro; 3 só se não dá para gravar)
  1 lê o registro, /proc/stat, /proc/meminfo e a tabela de processos  2 dá fim aos itens que acabaram (results.jsonl); item que bateu no teto de sistema leva KILL; sobrevivente na sessão de um item que já gravou o rc (órfão) leva TERM depois
  de BALLAST_ORPHAN_GRACE_S (180 s) e a rodada fecha pelo rc do item, com `orfaos` na linha  3 sem a chave `on`: mata o que roda e sai  4 RAM: pausa (SIGSTOP),
  retoma (SIGCONT) ou mata o maior  5 CPU livre = núcleos - carga(nice<=0); a conta de leituras livres seguidas anda ou zera  6 começa itens enquanto couberem no orçamento
  (núcleos livres - reserva): `work` primeiro; `filler` só com o que sobrar e é morto quando um `work` vai começar.
ITENS  (registro TSV, 8 colunas: nome papel núcleos rss_mb prazo_s cooldown_s requires comando)
  papel work|filler · núcleos inteiro ou `auto` (leva o resto do orçamento) · rss_mb teto da soma de RSS do item · requires `-` ou lista de path:/exec:/cmd:/flag:/noflag: (todos verdadeiros;
  predicado desconhecido = item inerte) · comando relativo vale a partir da pasta de itens. Linha malformada = erro visível em `registry_errors`; o item dela não roda e os outros seguem.
  O que roda é achado na TABELA DE PROCESSOS (o líder da sessão leva a marca `ballast-item:<item>:<rodada>` na linha de comando), não no state.json: perder o estado não duplica o que já roda.
TRÊS ESTADOS
  Toda leitura é leu / vazio / não consegui ler. "Não consegui ler" (registro, /proc/stat, meminfo, tabela de processos) nunca vira "livre" nem "morto": nada começa naquele tick, e sem ler a TABELA DE PROCESSOS nada é morto
  (/proc/stat e meminfo só decidem começo, pausa e morte por memória: desligar, fim de rodada e prazo seguem valendo sem eles).
  state.json corrompido ou de forma errada vai para <arquivo>.corrupt-<época> e recomeça; ilegível por permissão = rc 3 (inerte). A escrita da pasta é conferida ANTES de qualquer efeito.
  O que o tick não leu fica null no registro (running, registry_errors, mode), nunca [].
ARQUIVOS  (em $BALLAST_HOME, padrão ~/gt-remote/ballast)
  items.tsv · items/ · on (a chave: presente = ligado) · state.json · lock · ticks.jsonl · results.jsonl · runs/<rodada>/{meta.json,log,rc,final,cgroup,ceiling}
STOP  rc 0 = a sessão de cada item esvaziou (TERM+CONT, KILL 3 s depois no que sobrar) · 3 = não li os processos, nada foi morto · 5 = sobrou processo vivo (`survivors`) ou a tabela ficou
  ilegível depois do TERM (`unverified`): NÃO diz que parou · outro = o stop não rodou.
USO  hetzner-ballast.py tick | status [--json] | stop      env: BALLAST_HOME BALLAST_PROC BALLAST_NOW BALLAST_ITEMS BALLAST_ITEMS_DIR BALLAST_LAUNCH_PREFIX (JSON, com `nice`; BALLAST_TEST=1 só no selftest) BALLAST_CEILING (systemd; off só no selftest) BALLAST_TASKS_MAX BALLAST_MEM_FACTOR BALLAST_RUNTIME_DIR BALLAST_CGROUP_ROOT e os limites BALLAST_* de load_config
"""
import fcntl
import json
import math
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

MARK = "ballast-item:"
NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,40}$")
ROLES = ("work", "filler")


class Fail(Exception):
    """Não consigo gravar/ler algo que o tick precisa para ser seguro: exit 3, nada começa."""
    def __init__(self, msg, rc=3):
        Exception.__init__(self, msg)
        self.rc = rc


class Unreadable(Exception):
    """Uma leitura não respondeu: o tick registra a nota e não começa nem mata nada."""


# ---- configuração -------------------------------------------------------------------------------------------------------------------------------------
def _num(env, key, default, cast, lo):
    v = cast(env.get(key, default))
    if not v >= lo:  # NaN também reprova
        raise ValueError("%s=%r abaixo do mínimo %r" % (key, v, lo))
    return v


def _prefix(raw, test=False):
    """BALLAST_LAUNCH_PREFIX: vazio → o prefixo padrão; senão uma lista JSON de textos COM `nice` (BALLAST_TEST=1, só o selftest, dispensa). Qualquer outra coisa é configuração inválida
    (ValueError), nunca um prefixo sem nice por engano: sem o nice 19 o item NÃO seria lastro e a cidade o veria como carga."""
    if not raw:
        return None
    v = json.loads(raw)
    if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
        raise ValueError("BALLAST_LAUNCH_PREFIX tem que ser uma lista JSON de textos")
    if not test and "nice" not in v:
        raise ValueError("BALLAST_LAUNCH_PREFIX sem `nice`: o item seria carga, não lastro")
    return v


def _ceiling(raw, test=False):
    """BALLAST_CEILING: vazio/systemd → o teto de verdade; `off` só no selftest (BALLAST_TEST=1). Qualquer outra coisa é configuração inválida (ValueError): o lastro nunca roda sem teto por engano."""
    if raw in ("", "systemd"):
        return "systemd"
    if raw == "off" and test:
        return "off"
    raise ValueError("BALLAST_CEILING=%r inválido (systemd; off só no selftest)" % raw)


def load_config(env):
    home = env.get("BALLAST_HOME") or os.path.join(os.path.expanduser("~"), "gt-remote", "ballast")
    raw = env.get("BALLAST_NOW", "").strip()
    prefix = env.get("BALLAST_LAUNCH_PREFIX", "").strip()
    return SimpleNamespace(
        ceiling=_ceiling(env.get("BALLAST_CEILING", "").strip(), env.get("BALLAST_TEST") == "1"),
        tasks_max=_num(env, "BALLAST_TASKS_MAX", 4096, int, 16), mem_factor=_num(env, "BALLAST_MEM_FACTOR", 1.25, float, 1.0),
        runtime_dir=env.get("BALLAST_RUNTIME_DIR") or env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(), cgroup_root=env.get("BALLAST_CGROUP_ROOT") or "/sys/fs/cgroup",
        home=home, proc=env.get("BALLAST_PROC", "/proc"), now=int(raw) if raw else int(time.time()),
        registry=env.get("BALLAST_ITEMS") or os.path.join(home, "items.tsv"), items_dir=env.get("BALLAST_ITEMS_DIR") or os.path.join(home, "items"),
        idle_min_pct=_num(env, "BALLAST_IDLE_MIN_PCT", 15.0, float, 0.0), idle_ticks=_num(env, "BALLAST_IDLE_TICKS", 3, int, 1),
        reserve=_num(env, "BALLAST_RESERVE_CORES", 1.0, float, 0.0), max_items=_num(env, "BALLAST_MAX_ITEMS", 4, int, 1),
        gap_s=_num(env, "BALLAST_GAP_S", 180, int, 1), page_kb=_num(env, "BALLAST_PAGE_KB", 4, int, 1),
        ram_start_mb=_num(env, "BALLAST_RAM_START_MB", 14336, int, 0), ram_pause_mb=_num(env, "BALLAST_RAM_PAUSE_MB", 10240, int, 0),
        ram_resume_mb=_num(env, "BALLAST_RAM_RESUME_MB", 12288, int, 0), ram_kill_mb=_num(env, "BALLAST_RAM_KILL_MB", 7168, int, 0),
        pause_kill_ticks=_num(env, "BALLAST_PAUSE_KILL_TICKS", 5, int, 1), term_grace_s=_num(env, "BALLAST_TERM_GRACE_S", 20, int, 1),
        deadline_slack_s=_num(env, "BALLAST_DEADLINE_SLACK_S", 60, int, 0), fail_cooldown_s=_num(env, "BALLAST_FAIL_COOLDOWN_S", 600, int, 0),
        keep_runs=_num(env, "BALLAST_KEEP_RUNS", 30, int, 0), orphan_grace_s=_num(env, "BALLAST_ORPHAN_GRACE_S", 180, int, 0),
        launch_prefix=_prefix(prefix, env.get("BALLAST_TEST") == "1"))


# ---- leituras (cada uma com três estados) ---------------------------------------------------------------------------------------------------------------
def read_text(path):
    # vazio → texto vazio (o chamador decide se vazio vale); falhou/ilegível → Unreadable (nada começa, nada é morto)
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise Unreadable("%s: %s" % (path, e))


def read_stat(root):
    """(ncpu, [user nice system idle iowait irq softirq steal])."""
    # vazio → Unreadable (sem linha cpu); falhou/ilegível → Unreadable
    lines = read_text(os.path.join(root, "stat")).splitlines()
    f = lines[0].split() if lines else []
    if len(f) < 9 or f[0] != "cpu":
        raise Unreadable("/proc/stat: linha agregada estranha")
    try:
        vec = [int(x) for x in f[1:9]]
    except ValueError:
        raise Unreadable("/proc/stat: não numérico")
    ncpu = sum(1 for ln in lines if re.match(r"^cpu[0-9]+ ", ln))
    if ncpu < 1:
        raise Unreadable("/proc/stat: nenhum cpuN")
    return ncpu, vec


def read_mem_avail_mb(root):
    # vazio (sem a linha) → Unreadable, nunca 0 MB; falhou/ilegível → Unreadable
    for ln in read_text(os.path.join(root, "meminfo")).splitlines():
        if ln.startswith("MemAvailable:"):
            try:
                return int(ln.split()[1]) // 1024
            except (ValueError, IndexError):
                raise Unreadable("/proc/meminfo: MemAvailable não numérico")
    raise Unreadable("/proc/meminfo: sem MemAvailable")


def scan(root, page_kb):
    """Tabela de processos: [{pid, sid, state, rss_kb, cmd}]. Processo que some no meio da leitura é ignorado; a pasta que não abre, ou que lista processos e NENHUM lê, é Unreadable."""
    # vazio (nenhum pid listado) → lista vazia (ninguém roda); falhou/ilegível (pasta, ou pids listados e nenhum lido) → Unreadable (nada começa, nada é morto)
    try:
        names = os.listdir(root)
    except OSError as e:
        raise Unreadable("%s: %s" % (root, e))
    out = []
    seen = 0
    for nm in names:
        if not nm.isdigit():
            continue
        seen += 1
        d = os.path.join(root, nm)
        try:
            with open(os.path.join(d, "stat"), "rb") as f:
                data = f.read().decode("utf-8", "replace")
            rest = data[data.rindex(")") + 2:].split()
            st, sid = rest[0], int(rest[3])
            with open(os.path.join(d, "statm"), "rb") as f:
                rss = int(f.read().split()[1]) * page_kb
            with open(os.path.join(d, "cmdline"), "rb") as f:
                cmd = f.read().decode("utf-8", "replace")
        except (OSError, ValueError, IndexError):
            continue
        out.append({"pid": int(nm), "sid": sid, "state": st, "rss_kb": rss, "cmd": cmd})
    if seen and not out:
        raise Unreadable("%s: %d processos listados, nenhum legível" % (root, seen))
    return out


def running_items(procs, known=None, valid=None):
    """{rodada: {item, run, pid, state, rss_kb, members}}. O grupo do item é a SESSÃO do líder (pid == sid): vale o líder com a marca `ballast-item:<item>:<rodada>` na linha de comando
    E uma pasta runs/<rodada> NESTA pasta de lastro (`valid`; a marca sozinha não basta: o selftest do próprio governo roda como item do hq-selftests e deixa processos com a marca de outra pasta,
    que não são nossos e nunca podem ser contados nem mortos), e também a rodada que a meta.json conhece (`known`: rodada -> (item, pid)) cujo líder já morreu mas deixou filho vivo na sessão.
    Pid reaproveitado (líder vivo SEM a marca da rodada) não é o item; zumbi sem filho vivo também não. `valid` None = sem filtro (só para quem não tem pasta)."""
    known = dict(known or {})
    by_pid = {p["pid"]: p for p in procs}
    cand = {}
    for p in procs:
        if p["pid"] != p["sid"]:
            continue
        m = next((a for a in p["cmd"].split("\0") if a.startswith(MARK)), None)
        parts = m[len(MARK):].split(":") if m else []
        if len(parts) == 2 and NAME_RE.match(parts[0]) and (valid is None or parts[1] in valid):
            cand[parts[1]] = (parts[0], p["pid"])
    for run, (item, pid) in known.items():
        ldr = by_pid.get(pid)
        if run not in cand and (ldr is None or ldr["state"] == "Z"):
            cand[run] = (item, pid)
    out = {}
    for run, (item, pid) in cand.items():
        mem = [q for q in procs if q["sid"] == pid and q["state"] != "Z"]
        if mem:
            lead = by_pid.get(pid)
            out[run] = {"item": item, "run": run, "pid": pid, "state": lead["state"] if lead else "S", "rss_kb": sum(q["rss_kb"] for q in mem), "members": [q["pid"] for q in mem]}
    return out


def current_runs(cfg):
    """(procs, rodadas sem marca final, {rodada: dados do que roda}). Qualquer leitura que falha é Unreadable: sem ler NINGUÉM é dado por morto."""
    procs = scan(cfg.proc, cfg.page_kb)
    unf, valid = unfinished_runs(cfg)
    known = {}
    for r in unf:
        m = read_meta(cfg, r)
        # pid 0/1/negativo/bool não é líder de sessão de ninguém: sid 0 casaria com thread de kernel e killpg(0) acertaria o grupo do próprio tick
        if m and type(m.get("pid")) is int and m["pid"] > 1:
            known[r] = (m["item"], m["pid"])
    return procs, unf, running_items(procs, known, valid)


# ---- registro -----------------------------------------------------------------------------------------------------------------------------------------
def parse_registry(text):
    """(itens, erros). Linha malformada é erro visível e não vira item; o resto segue."""
    items, errors, seen = [], [], set()
    for i, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        c = [x.strip() for x in raw.split("\t")]
        if len(c) != 8:
            errors.append("linha %d: %d colunas (esperava 8)" % (i, len(c)))
            continue
        name, role, cores, rss, tmo, cool, req, cmd = c
        try:
            if not NAME_RE.match(name):
                raise ValueError("nome inválido %r" % name)
            if name in seen:
                raise ValueError("nome repetido %r" % name)
            if role not in ROLES:
                raise ValueError("papel %r (work|filler)" % role)
            ncores = "auto" if cores == "auto" else int(cores)
            if ncores != "auto" and ncores < 1:
                raise ValueError("núcleos %r < 1" % cores)
            rss_mb, tmo_s, cool_s = int(rss), int(tmo), int(cool)
            if rss_mb < 1 or tmo_s < 1 or cool_s < 0:
                raise ValueError("rss_mb/prazo < 1 ou cooldown < 0")
            if not req or not cmd:
                raise ValueError("requires ou comando vazio")
        except ValueError as e:
            errors.append("linha %d: %s" % (i, e))
            continue
        seen.add(name)
        items.append({"name": name, "role": role, "cores": ncores, "rss_mb": rss_mb, "timeout_s": tmo_s, "cooldown_s": cool_s, "requires": req, "command": cmd})
    return items, errors


def resolve_command(cfg, item):
    """argv do item, ou None. Relativo vale a partir da pasta de itens; precisa existir e ser executável."""
    try:
        argv = shlex.split(item["command"])
    except ValueError:
        return None, "comando ilegível"
    if not argv:
        return None, "comando vazio"
    if not os.path.isabs(argv[0]):
        argv[0] = os.path.join(cfg.items_dir, argv[0])
    if not (os.path.isfile(argv[0]) and os.access(argv[0], os.X_OK)):
        return None, "comando: %s ausente ou sem permissão de execução" % argv[0]
    return argv, ""


def check_requires(cfg, req):
    """(ok, motivo). Predicado desconhecido NUNCA vira 'sem requisito'."""
    if req == "-":
        return True, ""
    for term in req.split(","):
        pred, _, arg = term.strip().partition(":")
        if pred == "path":
            ok = bool(arg) and os.path.exists(os.path.expanduser(arg))
        elif pred == "exec":
            p = os.path.expanduser(arg)
            ok = bool(arg) and os.path.isfile(p) and os.access(p, os.X_OK)
        elif pred == "cmd":
            ok = bool(arg) and shutil.which(arg) is not None
        elif pred == "flag":
            ok = bool(arg) and "/" not in arg and os.path.exists(os.path.join(cfg.home, arg))
        elif pred == "noflag":
            ok = bool(arg) and "/" not in arg and not os.path.exists(os.path.join(cfg.home, arg))
        else:
            return False, "requires: predicado desconhecido %r" % term.strip()
        if not ok:
            return False, "requires: %s não vale" % term.strip()
    return True, ""


def eligibility(cfg, item, st, running_names):
    """(ok, motivo) do item AGORA: requisitos, comando, timeout no PATH, cooldown, já rodando."""
    if item["name"] in running_names:
        return False, "rodando"
    ok, why = check_requires(cfg, item["requires"])
    if not ok:
        return False, why
    argv, why = resolve_command(cfg, item)
    if argv is None:
        return False, why
    if shutil.which("timeout") is None:
        return False, "timeout ausente no PATH (sem prazo não começa)"
    until = st["cooldown"].get(item["name"], 0)
    if until > cfg.now:
        return False, "cooldown até %d" % until
    return True, ""


# ---- estado -------------------------------------------------------------------------------------------------------------------------------------------
def fresh_state():
    return {"v": 1, "last": None, "free_ticks": 0, "cooldown": {}, "term": {}, "killed": {}, "paused": False, "paused_ticks": 0}


def _int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def state_ok(st):
    """Forma do state.json: v 1, cooldown {nome: época}, free_ticks inteiro >= 0, last None ou {t, vec de 8 inteiros}; term {rodada: época}, killed {rodada: motivo}, paused bool e
    paused_ticks inteiro >= 0 quando existem (estado da 2/5 não os tem: load_state os completa). JSON válido de forma errada é corrompido, não estado."""
    if not (isinstance(st, dict) and st.get("v") == 1 and isinstance(st.get("cooldown"), dict) and all(_int(x) for x in st["cooldown"].values())):
        return False
    if not (isinstance(st.get("term", {}), dict) and all(_int(x) for x in st.get("term", {}).values())
            and isinstance(st.get("killed", {}), dict) and all(isinstance(x, str) for x in st.get("killed", {}).values())
            and isinstance(st.get("paused", False), bool) and _int(st.get("paused_ticks", 0)) and st.get("paused_ticks", 0) >= 0):
        return False
    last = st.get("last")
    return (_int(st.get("free_ticks")) and st["free_ticks"] >= 0
            and (last is None or (isinstance(last, dict) and _int(last.get("t")) and isinstance(last.get("vec"), list) and len(last["vec"]) == 8 and all(_int(x) for x in last["vec"]))))


def load_state(cfg):
    path = os.path.join(cfg.home, "state.json")
    # vazio (arquivo ausente) → estado novo; falhou por permissão/E-S → Fail rc 3 (inerte); corrompido ou de forma errada → vai para o lado e recomeça
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return fresh_state()
    except OSError as e:
        raise Fail("%s: não abre (%s)" % (path, e))
    try:
        st = json.loads(raw.decode("utf-8"))
        if not state_ok(st):
            raise ValueError("formato")
        for k, v in fresh_state().items():
            st.setdefault(k, v)
        return st
    except (ValueError, RecursionError, UnicodeDecodeError):
        aside = "%s.corrupt-%d" % (path, cfg.now)
        try:
            os.replace(path, aside)
        except OSError as e:
            raise Fail("%s: corrompido e não consegui pôr de lado (%s)" % (path, e))
        print("hetzner-ballast: %s corrompido; cópia em %s, recomeço" % (path, aside), file=sys.stderr)
        return fresh_state()


def trim_log(path, cap, keep):
    """Arquivo que o cron enche (cron.err): passou do teto, fica só o fim. O cron abre em modo de acréscimo, então segue escrevendo no novo fim. Ausente/ilegível → nada (log não derruba o tick)."""
    try:
        if os.path.getsize(path) > cap:
            with open(path, "rb") as f:
                f.seek(-keep, os.SEEK_END)
                tail = f.read()
            with open(path, "wb") as f:
                f.write(tail)
    except OSError:
        pass


def save_json(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except OSError as e:
        raise Fail("%s: não gravei (%s)" % (path, e))


def append_line(path, obj, cap=1000000):
    """Uma linha JSON no fim; passou do teto de bytes, fica só a metade mais nova (o histórico longo mora no mini, que puxa results.jsonl)."""
    try:
        if os.path.exists(path) and os.path.getsize(path) > cap:
            with open(path, "rb") as f:
                keep = f.read().splitlines(True)
            keep = keep[len(keep) // 2:]
            with open(path, "wb") as f:
                f.writelines(keep)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj) + "\n")
    except OSError as e:
        raise Fail("%s: não gravei (%s)" % (path, e))


# ---- lançamento ---------------------------------------------------------------------------------------------------------------------------------------
def default_prefix():
    """nice 19 + SCHED_IDLE + ionice idle, com o que existir no PATH (o nice é o que o /proc/stat conta como fundo; sem ele o item NÃO é lastro e o prefixo vazio é erro do chamador)."""
    pre = ["nice", "-n", "19"]
    if shutil.which("chrt"):
        pre += ["chrt", "-i", "0"]
    if shutil.which("ionice"):
        pre += ["ionice", "-c", "3"]
    return pre


# ---- teto de sistema por item (ga-kgnjkt8) -------------------------------------------------------------------------------------------------------------------
CG_RE = re.compile(r"^/(?:[A-Za-z0-9_.@:-]+/)*ballast\.slice/ballast-([a-z0-9_-]+)\.scope$")


def ceiling_ready(cfg):
    """(ok, motivo). `off` (só no selftest) vale sempre. Senão precisa de systemd-run no PATH e do barramento do gerenciador de usuário (<runtime>/bus): sem sessão aberta nem linger não há gerenciador e o item NÃO começa."""
    # vazio (sem systemd-run, sem barramento) → não pronto, com o motivo; falhou/ilegível (stat negado: exists dá False) → também não pronto: o nó já parou uma vez (29/10) por processo sem teto, e item sem teto é a mesma exposição
    if cfg.ceiling == "off":
        return True, ""
    if shutil.which("systemd-run") is None:
        return False, "systemd-run ausente do PATH"
    bus = os.path.join(cfg.runtime_dir, "bus")
    if not os.path.exists(bus):
        return False, "sem gerenciador de usuário do systemd (%s ausente: nenhuma sessão aberta e sem linger)" % bus
    return True, ""


def mem_cap_mb(cfg, item):
    """MemoryMax do item em MB: o rss_mb do registro (que o governo já aplica por minuto) vezes o fator; o kernel é a rede de baixo para o que passa entre dois ticks."""
    return int(math.ceil(item["rss_mb"] * cfg.mem_factor))


def cgroup_dir(cfg, run):
    """(pasta do cgroup do item, motivo). O item escreve o caminho dele em runs/<rodada>/cgroup (de dentro do escopo). Só vale o escopo DESTA rodada na ballast.slice, sem `.` nem `..`: o kill do governo
    nunca pode alcançar outro cgroup (a sessão de login de alguém, o cron)."""
    # vazio (arquivo vazio: o item ainda não escreveu) → (None, "ilegivel"); falhou/ilegível (ausente, sem permissão, não é texto) → (None, "ilegivel"); caminho de forma errada → (None, "caminho")
    try:
        with open(os.path.join(cfg.home, "runs", run, "cgroup"), "r", encoding="utf-8") as f:
            raw = f.read().strip()
    except (OSError, UnicodeDecodeError):
        return None, "ilegivel"
    if not raw:
        return None, "ilegivel"
    m = CG_RE.match(raw)
    if not m or m.group(1) != run or any(s in (".", "..") for s in raw.split("/")):
        return None, "caminho"
    return cfg.cgroup_root.rstrip("/") + raw, ""


def read_events(path):
    """{chave: inteiro} de um pids.events / memory.events, ou None."""
    # vazio (nenhuma linha `chave número`) → None, não "zero estouros"; falhou/ilegível (ausente, sem permissão, não é texto) → None
    try:
        with open(path, "r", encoding="ascii") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    out = {}
    for ln in text.splitlines():
        k, _, v = ln.partition(" ")
        if k and v.strip().isdigit():
            out[k] = int(v.strip())
    return out or None


def ceiling_hit(cfg, run, notes):
    """`teto-processos` se o kernel recusou fork no cgroup do item (pids.events max), `teto-memoria` se matou algo nele (memory.events oom_kill); None se não estourou OU se não consegui ler — a nota diz
    que a leitura do teto falhou nesta rodada (o kernel segue impondo o teto: só o governo fica sem informação, e isso nunca vira 'estourou' nem 'tudo certo' calado)."""
    d, why = cgroup_dir(cfg, run)
    if d is None:
        notes.append("teto-%s:%s" % (why, run))
        return None
    pe, me = read_events(os.path.join(d, "pids.events")), read_events(os.path.join(d, "memory.events"))
    if pe is None or me is None:
        notes.append("teto-ilegivel:%s" % run)
    if pe is not None and pe.get("max", 0) > 0:
        return "teto-processos"
    if me is not None and me.get("oom_kill", 0) > 0:
        return "teto-memoria"
    return None


def cgroup_kill(cfg, run):
    """Manda o kernel matar TUDO o que está no escopo do item (cgroup.kill, kernel >= 5.14), inclusive quem fez setsid e a sessão não enxerga. Só o escopo desta rodada (cgroup_dir)."""
    # vazio/falhou (cgroup sem o arquivo, já sumido, sem permissão, caminho que não valida) → False e nada feito: o kill por sessão já foi tentado e este é só o complemento
    d, _ = cgroup_dir(cfg, run)
    if d is None:
        return False
    try:
        with open(os.path.join(d, "cgroup.kill"), "w") as f:
            f.write("1")
        return True
    except OSError:
        return False


def read_ceiling_report(path):
    """{tasks_peak, tasks_hit, mem_peak_mb, oom_kill} do relatório que o item grava de dentro do escopo (runs/<rodada>/ceiling), ou None. Campo ilegível é null (não sei), nunca 0."""
    # vazio (arquivo vazio, ou nenhum campo legível) → None; falhou/ilegível (ausente, sem permissão, não é texto) → None; campo que não é número → null só nele
    try:
        with open(path, "r", encoding="ascii") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    kv = {}
    for ln in text.splitlines():
        k, _, v = ln.strip().partition(" ")
        kv[k] = int(v) if v.isdigit() else None
    mem = kv.get("mem_peak")
    rep = {"tasks_peak": kv.get("pids_peak"), "tasks_hit": kv.get("pids_hits"), "mem_peak_mb": mem // 1048576 if mem is not None else None, "oom_kill": kv.get("oom_kill")}
    return None if all(v is None for v in rep.values()) else rep


WRAP = ('{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; '
        '[ -z "$BALLAST_CEILING_ON" ] || { { cut -d: -f3 /proc/self/cgroup 2>/dev/null || :; } > "$BALLAST_RUN_DIR/cgroup.tmp"; mv "$BALLAST_RUN_DIR/cgroup.tmp" "$BALLAST_RUN_DIR/cgroup"; } 2>/dev/null; '
        '"$@"; echo $? > "$BALLAST_RUN_DIR/rc"; '
        '[ -z "$BALLAST_CEILING_ON" ] || { c=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup); '
        '{ echo "pids_peak $(cat $c/pids.peak)"; echo "mem_peak $(cat $c/memory.peak)"; sed -n "s/^max /pids_hits /p" $c/pids.events; sed -n "s/^oom_kill /oom_kill /p" $c/memory.events; } > "$BALLAST_RUN_DIR/ceiling"; } 2>/dev/null')


def start_item(cfg, item, cores):
    argv, why = resolve_command(cfg, item)
    if argv is None:
        raise Unreadable(why)
    ok, why = ceiling_ready(cfg)   # defesa em profundidade: o do_tick já não chega aqui sem teto
    if not ok:
        raise Unreadable("%s: sem teto, o item não começa (%s)" % (item["name"], why))
    run = "%s-%d" % (item["name"], cfg.now)
    rundir = os.path.join(cfg.home, "runs", run)
    k = 1
    while os.path.exists(rundir):
        k += 1
        run = "%s-%d-%d" % (item["name"], cfg.now, k)
        rundir = os.path.join(cfg.home, "runs", run)
    meta = {"item": item["name"], "role": item["role"], "cores": cores, "rss_mb": item["rss_mb"], "timeout_s": item["timeout_s"], "cooldown_s": item["cooldown_s"], "start": cfg.now}
    if cfg.ceiling == "systemd":
        meta["ceiling"] = {"tasks": cfg.tasks_max, "mem_mb": mem_cap_mb(cfg, item)}
    try:
        os.makedirs(rundir)
        save_json(os.path.join(rundir, "meta.json"), meta)
        log = open(os.path.join(rundir, "log"), "ab")
    except OSError as e:
        raise Fail("%s: não crio a rodada (%s)" % (rundir, e))
    env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": os.path.expanduser("~"), "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1", "BALLAST_HOME": cfg.home,
           "BALLAST_RUN_DIR": rundir, "BALLAST_CORES": str(cores), "BALLAST_ITEM": item["name"]}
    prefix = cfg.launch_prefix if cfg.launch_prefix is not None else default_prefix()
    # oom_score_adj 1000: se o nó (sem swap) ficar sem memória, o kernel mata o lastro antes de uma sessão (subir o próprio valor não pede root); sem /proc (macOS) a linha é silenciosa
    wrapper = ["sh", "-c", WRAP, MARK + item["name"] + ":" + run] + prefix + ["timeout", "-k", "30", str(item["timeout_s"])] + argv
    if cfg.ceiling == "systemd":
        # o escopo é criado pelo gerenciador de usuário ANTES do exec do item (systemd-run --scope faz exec no mesmo pid: a sessão e a marca continuam valendo); o item sai SEM o barramento, para não pedir
        # ao gerenciador um escopo fora do teto. OOMPolicy=continue: o kernel mata só o maior do cgroup e o item ainda grava o rc e os picos (o governo lê o oom_kill no tick).
        env["BALLAST_CEILING_ON"] = "1"
        wrapper = [shutil.which("systemd-run"), "--user", "--scope", "--quiet", "--collect", "--unit=ballast-" + run, "--slice=ballast.slice", "-p", "TasksMax=%d" % cfg.tasks_max,
                   "-p", "MemoryMax=%dM" % mem_cap_mb(cfg, item), "-p", "MemorySwapMax=0", "-p", "OOMPolicy=continue", "--", "env", "-u", "XDG_RUNTIME_DIR", "-u", "DBUS_SESSION_BUS_ADDRESS"] + wrapper
        penv = dict(env, XDG_RUNTIME_DIR=cfg.runtime_dir, DBUS_SESSION_BUS_ADDRESS="unix:path=" + os.path.join(cfg.runtime_dir, "bus"))
    else:
        penv = env
    try:
        p = subprocess.Popen(wrapper, cwd=rundir, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=penv, start_new_session=True, close_fds=True)
    except OSError as e:
        raise Unreadable("%s: não executou (%s)" % (item["name"], e))
    finally:
        log.close()
    # o pid na meta: se o líder morrer deixando filho vivo na sessão, a rodada ainda é achada (a marca só vive na linha de comando do líder)
    save_json(os.path.join(rundir, "meta.json"), dict(meta, pid=p.pid))
    return {"item": item["name"], "run": run, "pid": p.pid, "cores": cores}


# ---- sinais e fim de rodada ---------------------------------------------------------------------------------------------------------------------------
def send(r, sig):
    """Manda o sinal ao grupo inteiro do item (sessão própria) e a cada membro (um filho que mudou de grupo continua na sessão). Não existe mais = False."""
    hit = False
    try:
        os.killpg(r["pid"], sig)
        hit = True
    except ProcessLookupError:
        pass
    except PermissionError:
        return False
    for m in r["members"]:
        try:
            os.kill(m, sig)
            hit = True
        except (ProcessLookupError, PermissionError):
            pass
    return hit


def terminate(cfg, st, r, why, rec):
    """TERM (+CONT, que um grupo parado não trata TERM); o KILL vem num tick depois se o grupo seguir vivo."""
    send(r, signal.SIGTERM)
    send(r, signal.SIGCONT)
    st["term"][r["run"]] = cfg.now
    st["killed"].setdefault(r["run"], why)
    rec["killed"].append({"item": r["item"], "run": r["run"], "why": why, "sig": "TERM"})


def kill_now(cfg, st, r, why, rec):
    send(r, signal.SIGKILL)
    cgroup_kill(cfg, r["run"])   # quem fez setsid sai da sessão e o send() não o alcança; o cgroup alcança
    st["term"][r["run"]] = cfg.now
    st["killed"][r["run"]] = why
    rec["killed"].append({"item": r["item"], "run": r["run"], "why": why, "sig": "KILL"})


def read_meta(cfg, run):
    # vazio/ilegível → None (a rodada é encerrada com o nome do item tirado do nome da pasta, sem tamanho nem prazo)
    try:
        with open(os.path.join(cfg.home, "runs", run, "meta.json"), "r", encoding="utf-8") as f:
            m = json.load(f)
        return m if isinstance(m, dict) and isinstance(m.get("item"), str) else None
    except (OSError, ValueError, RecursionError):
        return None


def read_summary(path):
    """(resumo|None, porque). Vale a ÚLTIMA linha `BALLAST-SUMMARY: {json}` do fim do log; o que não for objeto JSON é ilegível, nunca dado."""
    # vazio (nenhuma linha de resumo) → (None, 'ausente'); falhou/ilegível → (None, 'log-ilegivel'); resumo que não é objeto → (None, 'ilegivel')
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return None, "log-ilegivel"
    lines = [ln for ln in tail.splitlines() if ln.startswith("BALLAST-SUMMARY: ")]
    if not lines:
        return None, "ausente"
    try:
        v = json.loads(lines[-1][len("BALLAST-SUMMARY: "):])
    except (ValueError, RecursionError):
        return None, "ilegivel"
    return (v, "") if isinstance(v, dict) else (None, "ilegivel")


def orphaned(cfg, run, start):
    """True = a rodada ainda tem gente na sessão MAS o item já terminou: o `rc` do lançamento foi gravado há pelo menos a graça (BALLAST_ORPHAN_GRACE_S). O que sobra depois do rc é órfão (selftest que
    não limpa, mux do ssh…). Sem isto a rodada fica 'rodando' até o último órfão sair (16 a 45 min nas rodadas do hq-selftests de 24/10) e segura os núcleos dela no orçamento."""
    # vazio (sem rc: o item ainda roda) → False; falhou/ilegível (rc que não é inteiro, sem permissão, meta sem start, carimbo anterior ao início da rodada = relógio que não é o desta rodada) → False
    # também: o lado que NÃO mata (a idade do rc só vale se o carimbo é desta rodada)
    p = os.path.join(cfg.home, "runs", run, "rc")
    try:
        with open(p, "r", encoding="ascii") as f:
            int(f.read().strip())
        t = int(os.stat(p).st_mtime)
    except (OSError, ValueError):
        return False
    return _int(start) and t >= start and cfg.now - t >= cfg.orphan_grace_s


def finalize(cfg, st, run, rec):
    """Encerra uma rodada que não tem mais processo: results.jsonl, cooldown, marca final. rc ilegível/ausente NUNCA vira ok."""
    rundir = os.path.join(cfg.home, "runs", run)
    meta = read_meta(cfg, run)
    item = meta["item"] if meta else re.sub(r"-[0-9]{9,}(-[0-9]+)?$", "", run)   # a rodada é <item>-<época>[-<n>]; o item pode terminar em número (a-12)
    # vazio (sem arquivo rc) → rc None = morreu sem avisar; falhou/ilegível (não é inteiro) → também None
    rc = None
    try:
        with open(os.path.join(rundir, "rc"), "r", encoding="ascii") as f:
            rc = int(f.read().strip())
    except (OSError, ValueError):
        pass
    killed = st["killed"].pop(run, None)
    st["term"].pop(run, None)
    # picos do item lidos de dentro do escopo (null = não sei); o que sobrou no cgroup (quem fez setsid) leva kill: a rodada acabou
    rep = read_ceiling_report(os.path.join(rundir, "ceiling"))
    cgroup_kill(cfg, run)
    # órfãos: o item JÁ tinha gravado o rc e o governo só limpou o que sobrou; o desfecho é o do item (ok / rc-N), nunca "orfaos" (uma rodada boa ganharia o cooldown de falha)
    orph = killed == "orfaos"
    # o relatório dizendo fork recusado / oom_kill vale mesmo com rc 0: o item bateu no teto, a rodada não é 'ok'
    hit = ("teto-processos" if (rep or {}).get("tasks_hit") else "teto-memoria" if (rep or {}).get("oom_kill") else None)
    why = (None if orph else killed) or hit or ("ok" if rc == 0 else ("rc-%d" % rc if rc is not None else "morreu-sem-rc"))
    summ, summ_why = read_summary(os.path.join(rundir, "log"))
    start = meta.get("start") if meta else None
    row = {"ts": iso(cfg.now), "item": item, "run": run, "role": meta.get("role") if meta else None, "cores": meta.get("cores") if meta else None, "start": start,
           "secs": (cfg.now - start) if isinstance(start, int) else None, "rc": rc, "why": why, "summary": summ, "summary_why": summ_why, "ceiling": rep}
    if orph:
        row["orfaos"] = True
    # a linha de resultado vem ANTES da marca: se a marca não grava, o tick seguinte repete a linha (repetida é melhor que perdida)
    append_line(os.path.join(cfg.home, "results.jsonl"), row, 2000000)
    try:
        with open(os.path.join(rundir, "final"), "w") as f:
            f.write("%d\n" % cfg.now)
    except OSError as e:
        raise Fail("%s: não marquei a rodada como final (%s)" % (rundir, e))
    # vazio/ilegível (meta.json sumida ou cooldown_s que não é inteiro >= 0) → o cooldown de falha: não sei o do item, e errar para menos o recomeçaria em cima
    cool = meta.get("cooldown_s") if meta else None
    if not (_int(cool) and cool >= 0):
        cool = cfg.fail_cooldown_s
    if why not in ("ok", "desligado", "preempt", "stop"):
        cool = max(cool, cfg.fail_cooldown_s)
    st["cooldown"][item] = cfg.now + cool
    rec["reaped"].append({"item": item, "run": run, "rc": rc, "why": why})


def prune_runs(cfg):
    """Fica com as `keep_runs` rodadas ENCERRADAS mais novas; a que roda e a sem marca final nunca são apagadas."""
    base = os.path.join(cfg.home, "runs")
    fin = []
    try:
        for d in os.listdir(base):
            try:
                with open(os.path.join(base, d, "final"), "r") as f:
                    fin.append((int(f.read().strip()), d))
            except (OSError, ValueError):
                continue
    except OSError:
        return
    fin.sort()
    for _, d in fin[:max(0, len(fin) - cfg.keep_runs)]:
        path = os.path.join(base, d)
        if os.path.dirname(os.path.realpath(path)) == os.path.realpath(base):
            shutil.rmtree(path, ignore_errors=True)


def unfinished_runs(cfg):
    """(rodadas sem marca final, todas as rodadas desta pasta)."""
    base = os.path.join(cfg.home, "runs")
    # vazio (sem pasta runs) → nenhuma rodada; falhou/ilegível → Unreadable (não encerra nada por palpite)
    try:
        names = os.listdir(base)
    except FileNotFoundError:
        return [], set()
    except OSError as e:
        raise Unreadable("%s: %s" % (base, e))
    alld = set(d for d in names if os.path.isdir(os.path.join(base, d)))
    return sorted(d for d in alld if not os.path.exists(os.path.join(base, d, "final"))), alld


# ---- o tick -------------------------------------------------------------------------------------------------------------------------------------------
def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))


def load_registry(cfg):
    # vazio (nenhuma linha de item) → lista vazia (nada a rodar); falhou/ilegível → Unreadable (nada começa; o que já roda continua)
    return parse_registry(read_text(cfg.registry))


def running_cores(cfg, run, items, budget, notes):
    reg = {it["name"]: it["cores"] for it in items}
    tot = 0
    for r in run.values():
        m = read_meta(cfg, r["run"])
        c = m.get("cores") if m else None
        # vazio/ilegível (meta ausente, sem núcleos ou < 1) → o que o registro diz do item; `auto` ou fora do registro = o orçamento inteiro: errar para menos começaria item demais
        if not (_int(c) and c >= 1):
            c = reg.get(r["item"], "auto")
            c = budget if c == "auto" else c
            notes.append("cores-desconhecidos:%s" % r["run"])
        tot += c
    return tot


def cpu_step(cfg, st, vec, ncpu, rec, notes):
    """Carga = user+system+irq+softirq+steal (nice <= 0). O tempo em nice > 0 é o próprio lastro (e qualquer fundo): não conta. True = leitura boa, sem lacuna."""
    last = st.get("last")
    ok = False
    if not last or any(v < l for v, l in zip(vec, last["vec"])):
        st["free_ticks"] = 0
        notes.append("primeira-leitura")
    else:
        d = [v - l for v, l in zip(vec, last["vec"])]
        dt = sum(d)
        if dt <= 0:
            st["free_ticks"] = 0
            notes.append("leitura-ilegivel")
        else:
            fg = (d[0] + d[2] + d[5] + d[6] + d[7]) / float(dt)
            rec["fg_cores"], rec["free_pct"] = round(fg * ncpu, 1), round(100.0 * (1.0 - fg), 1)
            if cfg.now - last["t"] > cfg.gap_s:
                st["free_ticks"] = 0
                notes.append("lacuna")
            else:
                ok = True
                st["free_ticks"] = st["free_ticks"] + 1 if rec["free_pct"] >= cfg.idle_min_pct else 0
    st["last"] = {"t": cfg.now, "vec": vec}
    return ok


def ram_step(cfg, st, run, mem, rec):
    """RAM: abaixo do piso crítico mata o maior na hora; abaixo do de pausa congela (SIGSTOP) e, se não passar em N leituras, mata o maior; com folga retoma (SIGCONT)."""
    biggest = max(run.values(), key=lambda r: r["rss_kb"]) if run else None
    if mem < cfg.ram_kill_mb:
        rec["ram"] = "critica"
        if biggest:
            kill_now(cfg, st, biggest, "ram-critica", rec)
            del run[biggest["run"]]
    elif mem < cfg.ram_pause_mb or (st["paused"] and mem < cfg.ram_resume_mb):
        rec["ram"] = "pausa"
        if run:
            for r in run.values():
                send(r, signal.SIGSTOP)
            st["paused"] = True
            st["paused_ticks"] += 1
            if st["paused_ticks"] >= cfg.pause_kill_ticks:
                kill_now(cfg, st, biggest, "ram-pausa", rec)
                del run[biggest["run"]]
                st["paused_ticks"] = 0
    else:
        rec["ram"] = "ok"
        if st["paused"]:
            for r in run.values():
                send(r, signal.SIGCONT)
        st["paused"], st["paused_ticks"] = False, 0
    if not run:
        st["paused"], st["paused_ticks"] = False, 0
    rec["paused"] = st["paused"]


def do_tick(cfg):
    # o que este tick NÃO leu fica null (mode, running, registry_errors, paused), nunca um valor padrão que pareça leitura; started/killed/reaped/skipped são o que o tick FEZ: vazio = nada
    rec = {"ts": iso(cfg.now), "t": cfg.now, "mode": None, "note": "", "started": [], "running": None, "killed": [], "reaped": [], "skipped": [], "registry_errors": None, "ram": None,
           "paused": None}
    try:
        os.makedirs(cfg.home, exist_ok=True)
        lock = open(os.path.join(cfg.home, "lock"), "w")
    except OSError as e:
        raise Fail("%s: não crio a pasta/lock (%s)" % (cfg.home, e))
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        rec["note"] = "outra-instancia"
        return rec
    # a escrita é conferida ANTES de qualquer efeito: item começado e estado que não grava = item que ninguém controla
    probe = os.path.join(cfg.home, ".w.%d" % os.getpid())
    try:
        with open(probe, "w") as f:
            f.write("x")
        os.remove(probe)
    except OSError as e:
        raise Fail("%s: não consigo gravar (%s)" % (cfg.home, e))
    trim_log(os.path.join(cfg.home, "cron.err"), 262144, 65536)
    st = load_state(cfg)
    rec["paused"] = st["paused"]
    # vazio (sem a chave) → desligado; falhou/ilegível (stat negado) → também desligado: o lado que PARA o lastro (a pasta acabou de aceitar escrita, então nem deve acontecer)
    on = os.path.exists(os.path.join(cfg.home, "on"))
    rec["mode"] = "ligado" if on else "desligado"
    items, notes = [], []
    try:
        items, rec["registry_errors"] = load_registry(cfg)
    except Unreadable as e:
        notes.append("registro-ilegivel")
        print("hetzner-ballast: %s" % e, file=sys.stderr)
    ncpu = vec = mem = procs = None
    run = {}
    # cada leitura falha sozinha: /proc/stat e meminfo só decidem começo, pausa e morte por memória; desligar, fim de rodada e prazo dependem só da tabela de processos e não podem parar por causa deles
    bad = []
    try:
        ncpu, vec = read_stat(cfg.proc)
    except Unreadable as e:
        bad.append(e)
    try:
        mem = read_mem_avail_mb(cfg.proc)
    except Unreadable as e:
        bad.append(e)
    try:
        procs, unf, run = current_runs(cfg)
        # rodada sem processo vivo na sessão e sem marca final = acabou (ou morreu): encerra. Sem ler os processos NINGUÉM é dado por morto.
        for r in unf:
            if r not in run:
                finalize(cfg, st, r, rec)
        prune_runs(cfg)
    except Unreadable as e:
        bad.append(e)
        procs = None
    for e in bad:
        print("hetzner-ballast: %s" % e, file=sys.stderr)
    if bad:
        notes.append("leitura-ilegivel")
    rec["ncpu"], rec["mem_avail_mb"] = ncpu, mem
    seen_names = {r["item"] for r in run.values()}   # o que existia ANTES de qualquer sinal deste tick: quem leva TERM e ainda morre não pode ser recomeçado em cima
    free_ok = False
    if vec is not None:
        free_ok = cpu_step(cfg, st, vec, ncpu, rec, notes)
    rec["free_ticks"] = st["free_ticks"]
    if procs is not None:
        # quem já levou TERM e segue vivo depois da graça leva KILL; prazo estourado (+ folga) leva TERM
        for r in list(run.values()):
            t = st["term"].get(r["run"])
            m = read_meta(cfg, r["run"])
            if m is None:
                notes.append("meta-ilegivel:%s" % r["run"])
            m = m or {}
            # vazio/ilegível (meta.json sem start, timeout_s ou rss_mb inteiros) → sem prazo e sem teto de RSS para ESTE item neste tick (com a nota acima): não mata por palpite (o `timeout -k` do lançamento ainda o limita)
            start, tmo, cap = m.get("start"), m.get("timeout_s"), m.get("rss_mb")
            # teto de sistema: só lê o cgroup de quem foi lançado sob teto (meta.ceiling) e ainda não levou sinal; um estouro NÃO espera a graça do TERM (item que bateu no teto é lixo)
            breach = ceiling_hit(cfg, r["run"], notes) if (t is None and on and m.get("ceiling")) else None
            if t is not None:
                if cfg.now - t >= cfg.term_grace_s:
                    kill_now(cfg, st, r, st["killed"].get(r["run"], "term-ignorado"), rec)
                    del run[r["run"]]
                else:
                    del run[r["run"]]       # já foi avisado: não conta como rodando para o resto do tick
            elif not on:
                terminate(cfg, st, r, "desligado", rec)
                del run[r["run"]]
            elif breach:
                kill_now(cfg, st, r, breach, rec)
                del run[r["run"]]
            elif _int(start) and _int(tmo) and cfg.now - start > tmo + cfg.deadline_slack_s:
                terminate(cfg, st, r, "prazo", rec)
                del run[r["run"]]
            elif _int(cap) and r["rss_kb"] > cap * 1024:
                terminate(cfg, st, r, "rss", rec)
                del run[r["run"]]
            elif orphaned(cfg, r["run"], start):   # o item acabou (rc gravado) e a sessão ainda tem gente: limpa; sai do orçamento já neste tick
                terminate(cfg, st, r, "orfaos", rec)
                del run[r["run"]]
        if mem is not None and on:
            ram_step(cfg, st, run, mem, rec)
    # vazio (nada roda) → []; falhou/ilegível (tabela de processos) → null, nunca []
    rec["running"] = sorted(r["item"] for r in run.values()) if procs is not None else None
    # começar itens: ligado, tudo lido, CPU livre por idle_ticks leituras seguidas, orçamento = núcleos livres - reserva. `work` primeiro; `filler` só com o que sobrar.
    # sem teto não começa nada: o nó já parou uma vez (29/10) por processo sem teto, e item sem teto é a mesma exposição; a nota fica no registro do tick e o motivo no stderr (cron.err)
    ceil_ok, ceil_why = ceiling_ready(cfg)
    if on and not ceil_ok:
        notes.append("sem-teto")
        print("hetzner-ballast: sem teto (%s): nenhum item começa" % ceil_why, file=sys.stderr)
    block = any(n.startswith(("leitura-ilegivel", "registro-ilegivel", "primeira-leitura", "lacuna", "sem-teto")) for n in notes)
    if on and procs is not None and not block and free_ok and mem is not None and not st["paused"] and st["free_ticks"] >= cfg.idle_ticks:
        budget = int(ncpu - rec["fg_cores"] - cfg.reserve + 1e-9)
        running_names = seen_names | {k["item"] for k in rec["killed"]}
        # só `work` ocupa o orçamento do `work`; o filler que roda é o que sobrou e sai da frente (preempt) quando um work vai começar
        used0 = running_cores(cfg, {k: r for k, r in run.items() if (read_meta(cfg, r["run"]) or {}).get("role") != "filler"}, items, budget, notes)
        used = used0
        mem_left = mem   # a RAM é lida uma vez por tick: cada item PLANEJADO já a desconta, senão dois itens "cabem" na mesma sobra (planejado que não começa só deixa o filler mais cauteloso)
        plan = []
        for it in items:
            if it["role"] != "work":
                continue
            ok, why = eligibility(cfg, it, st, running_names)
            cores = it["cores"] if it["cores"] != "auto" else budget - used
            if not ok or cores < 1 or used + cores > budget:
                continue
            if mem_left - it["rss_mb"] < cfg.ram_start_mb:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append((it, cores))
            used += cores
            mem_left -= it["rss_mb"]
        if plan:   # um work vai começar: os fillers saem da frente (e voltam no tick seguinte com o que sobrar)
            for r in list(run.values()):
                m = read_meta(cfg, r["run"]) or {}
                if m.get("role") == "filler" and r["run"] not in st["term"]:
                    terminate(cfg, st, r, "preempt", rec)
                    del run[r["run"]]
        for it, cores in plan:
            if len(run) + len(rec["started"]) >= cfg.max_items:
                break
            try:
                rec["started"].append(start_item(cfg, it, cores))
            except Unreadable as e:
                notes.append("nao-comecou:%s" % it["name"])
                print("hetzner-ballast: %s" % e, file=sys.stderr)
        fill_used = used0 + sum(r["cores"] for r in rec["started"])
        for it in items:
            if it["role"] != "filler" or len(run) + len(rec["started"]) >= cfg.max_items:
                continue
            ok, why = eligibility(cfg, it, st, running_names)
            cores = it["cores"] if it["cores"] != "auto" else budget - fill_used
            if not ok or cores < 1 or (it["cores"] != "auto" and fill_used + cores > budget):
                continue
            if mem_left - it["rss_mb"] < cfg.ram_start_mb:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            try:
                rec["started"].append(start_item(cfg, it, cores))
                fill_used += cores
                mem_left -= it["rss_mb"]
            except Unreadable as e:
                notes.append("nao-comecou:%s" % it["name"])
                print("hetzner-ballast: %s" % e, file=sys.stderr)
    rec["note"] = ",".join(notes)
    save_json(os.path.join(cfg.home, "state.json"), st)
    append_line(os.path.join(cfg.home, "ticks.jsonl"), rec)
    return rec


def survivors(cfg, run):
    """{rodada: [pids]} do que AINDA vive na SESSÃO de cada rodada. A sessão, não o grupo do líder: o `timeout` do GNU troca de grupo e o item segue na sessão com o líder já morto."""
    # vazio (ninguém vivo na sessão) → {}; falhou/ilegível (tabela de processos) → Unreadable = não sei, pode haver sobrevivente (quem chama NÃO conclui que parou)
    procs = scan(cfg.proc, cfg.page_kb)
    left = {}
    for r in run.values():
        alive = [p["pid"] for p in procs if p["sid"] == r["pid"] and p["state"] != "Z" and pid_exists(p["pid"])]
        if alive:
            left[r["run"]] = alive
    return left


def pid_exists(pid):
    """A linha do /proc pode ser mais velha que o processo: confirma com o sinal 0 (sem permissão = existe)."""
    # vazio (ESRCH, sumiu) → False; falhou/ilegível (EPERM, não posso sinalizar) → True: na dúvida conta como vivo, nunca como parado
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_gone(cfg, run, secs):
    """Espera até `secs` s a sessão de cada rodada esvaziar: {} = esvaziou · {rodada: pids} = sobrou · None = não consegui ler a tabela (não sei)."""
    end = time.time() + secs
    while True:
        try:
            left = survivors(cfg, run)
        except Unreadable:
            return None
        if not left or time.time() >= end:
            return left
        time.sleep(0.2)


def do_stop(cfg):
    """Mata tudo o que roda (TERM+CONT; KILL 3 s depois no que sobrar NA SESSÃO) e anota o motivo `stop` na rodada, para o results.jsonl não dizer que ela morreu sozinha. Só diz que parou
    o que a tabela de processos mostra vazio: sobrou algo depois do KILL → `survivors`, tabela ilegível → `unverified`, e o rc é 5 nos dois casos. Sem ler os processos antes não mata nada
    e sai 3 (sem ler DEPOIS do TERM também não manda KILL: não mata às cegas). Se um tick está rodando (lock tomado por mais de 5 s) ou o estado não abre, mata do mesmo jeito e a rodada
    sai como morreu-sem-rc: parar vale mais que a anotação."""
    try:
        _procs, unf, run = current_runs(cfg)
    except Unreadable as e:
        raise Fail("stop: não consegui ler os processos (%s)" % e)
    out = {"stopped": []}
    lock, st = None, None
    try:
        os.makedirs(cfg.home, exist_ok=True)
        lock = open(os.path.join(cfg.home, "lock"), "w")
        for _ in range(25):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                st = load_state(cfg)
                break
            except OSError:
                time.sleep(0.2)
    except (OSError, Fail):
        st = None
    for r in run.values():
        send(r, signal.SIGTERM)
        send(r, signal.SIGCONT)
        if st is not None:
            st["killed"].setdefault(r["run"], "stop")
        out["stopped"].append({"item": r["item"], "run": r["run"], "pid": r["pid"]})
    if st is not None:
        try:
            save_json(os.path.join(cfg.home, "state.json"), st)
        except Fail:
            pass
    left = wait_gone(cfg, run, 3) if run else {}
    for rn in unf:   # quem fez setsid sai da sessão e `wait_gone` não o vê: o cgroup de toda rodada aberta leva kill (rodada sem teto/sem cgroup: nada a fazer)
        cgroup_kill(cfg, rn)
    if left:   # o que sobrou na sessão (inclusive filho que o item pôs no mundo depois do 1º scan) leva KILL pelo pid, e o grupo do líder junto
        for rn, pids in left.items():
            send(dict(run[rn], members=pids), signal.SIGKILL)
        left = wait_gone(cfg, run, 2)
    if left is None:
        out["stopped"], out["unverified"] = [], True
    elif left:
        out["stopped"] = [x for x in out["stopped"] if x["run"] not in left]
        out["survivors"] = left
    return out


# ---- status -------------------------------------------------------------------------------------------------------------------------------------------
def do_status(cfg):
    ceil_ok, ceil_why = ceiling_ready(cfg)
    out = {"home": cfg.home, "mode": "ligado" if os.path.exists(os.path.join(cfg.home, "on")) else "desligado", "state": "ok", "items": [], "registry_errors": [], "running": [],
           "launch_prefix": cfg.launch_prefix if cfg.launch_prefix is not None else default_prefix(),
           "ceiling": {"mode": cfg.ceiling, "ready": ceil_ok, "why": ceil_why, "tasks_max": cfg.tasks_max, "mem_factor": cfg.mem_factor}}
    st = fresh_state()
    try:
        with open(os.path.join(cfg.home, "state.json"), "rb") as f:
            st = json.loads(f.read().decode("utf-8"))
        if not state_ok(st):
            st = fresh_state()
            out["state"] = "ilegivel"
    except FileNotFoundError:
        out["state"] = "ausente"
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        out["state"] = "ilegivel"   # status só LÊ: ausente = "sem cooldown"; ilegível/de forma errada = "sem cooldown" MAS avisado em `state`, sem gravar nada
    try:
        items, out["registry_errors"] = load_registry(cfg)
    except Unreadable as e:
        out["registry_errors"] = ["registro ilegível: %s" % e]
        items = []
    try:
        run = current_runs(cfg)[2]
        out["running"] = sorted(r["item"] for r in run.values())
    except Unreadable as e:
        out["running"] = None
        run = {}
    names = {r["item"] for r in run.values()}
    for it in items:
        ok, why = eligibility(cfg, it, st, names)
        out["items"].append({"name": it["name"], "role": it["role"], "cores": it["cores"], "eligible": ok, "why": why})
    return out


def main(argv):
    try:
        cfg = load_config(os.environ)
    except (ValueError, json.JSONDecodeError) as e:
        print("hetzner-ballast: configuração inválida: %s" % e, file=sys.stderr)
        return 3
    cmd = argv[0] if argv else ""
    try:
        if cmd == "tick":
            print(json.dumps(do_tick(cfg)))
            return 0
        if cmd == "status":
            print(json.dumps(do_status(cfg)))
            return 0
        if cmd == "stop":
            out = do_stop(cfg)
            print(json.dumps(out))
            return 5 if out.get("survivors") or out.get("unverified") else 0
    except Fail as e:
        print("hetzner-ballast: %s" % e, file=sys.stderr)
        return e.rc
    print("uso: hetzner-ballast.py tick | status [--json] | stop", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
