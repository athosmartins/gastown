#!/usr/bin/env python3
"""hetzner-occupancy-watch.py — o nó Hetzner pago está trabalhando? Uma leitura a cada 15 min; aviso ao Mayor se ocioso com fila ou se a CPU fica abaixo da régua. (ga-2hd02v.1.12, ga-2hd02v.6)

Contents
  Regra · Estado · Aviso · Arquivos · Uso

REGRA (Athos, 14/10): "Hetzner pago trabalha sempre". O launchd do mini roda isto a cada 900 s (com.gascity.hetzner-occupancy-watch). Cada rodada faz TRÊS
leituras, e cada uma tem três estados (leu / não consegui ler / vale X): "não consegui" nunca vira "ocioso" nem "ocupado".
  sessões  `gc session list --json`: sessões com `-remote-` no nome em state active/awake (as de `-remote-mbp-` são de outro host e não contam), e `bd list --status
           in_progress --json --limit 0` (só leitura): dessas, só conta a que SEGURA uma bead (assignee = o alias, o session_name ou o name dela)
  CPU     `ssh hetzner-teste` lê o /proc/stat: núcleos ocupados NA JANELA desde a leitura anterior (uma rajada entre duas leituras aparece; um instante não vale)
  fila     ~/.gc/pilot-dispatchable.json (o Pilot a grava a cada rodada): só as lojas elegíveis (hq), com idade e ttl conferidos
ESTADO   ocupado = sessão remota que SEGURA bead in_progress OU CPU >= régua (0,5 núcleo, HETZNER_OCC_BUSY_CORES): uma prova basta. Sessão viva sem bead NÃO prova nada
         (20/10: 2 dog-remote paradas, beads fechadas, 26 de 26 leituras "ocupado" com CPU de 1 a 18 %, ga-l9q18u); o bd que falha não vira "ninguém segura bead"
         ocioso  = sessões (e quem segura bead) e CPU lidas e as duas dizem ocioso
         desconhecido = o resto (inclui a 1ª leitura, que só semeia o baseline de CPU)
AVISO    ao Mayor por `gc mail send` (não nudge: o nudge ao Mayor trava com a sessão anexada, ga-eldeu). Só avisa; não atribui nem despacha nada.
  ocioso   ocioso há >= 30 min (3 leituras seguidas, 2 min de folga para o jitter do launchd) COM fila > 0; cooldown de 3 h; o mail que falha não gasta o cooldown
  cpu baixa  a CPU do nó abaixo de 85 % (HETZNER_OCC_LOW_PCT; 0 desliga) por >= 30 min: janelas de CPU seguidas, cada uma com média abaixo da régua, que juntas cobrem 30 min medidos (2 min de folga);
           cooldown de 3 h. Só olha a CPU: NÃO depende de fila, de sessão nem do foco do gate. Athos, 20/10: "o que nao pode é ficar menos do que 100% ocupado"; na madrugada de 20/10 a CPU ficou em
           0-15 % por 7 h e nenhum aviso saiu, porque toda leitura era "ocupado" (havia sessão segurando bead)
  cego     nenhuma leitura decidiu o estado há >= 1 h (sessões, CPU ou fila ilegíveis), OU a CPU não é lida há >= 1 h (com a CPU cega o aviso de CPU baixa está mudo, mesmo que a sessão prove "ocupado"); cooldown de 6 h
  foco     o foco do gate (gate-focus.state, mesma regra de 3 estados da gate-focus-lib.sh) liga: só conserto é despachado, então o aviso de ocioso se cala
  chave    o aviso só sai com <cidade>/.gc/hetzner-occupancy-alarm.on presente (e sem HETZNER_OCC_ALARM=0): sem ela é o modo só-medir, INERTE de propósito (mede e grava, nunca manda mail)
ARQUIVOS (só em <cidade>/.gc): hetzner-occupancy.jsonl (uma leitura por rodada) · hetzner-occupancy-daily.json (o número por dia: ocupado/ocioso/desconhecido;
  ocupacao_pct = a média de CPU do nó no dia, ponderada pela janela (cpu_nucleos_s / cpu_capacidade_s; cpu_janelas = quantas janelas entraram), null se nenhuma janela foi lida;
  ocupacao_sessao_pct = ocupado/(ocupado+ocioso), o número que ocupacao_pct era até a ga-2hd02v.6, null se nenhuma leitura decidiu. Dia gravado antes dela fica com o número antigo
  em ocupacao_sessao_pct e ocupacao_pct null: a CPU daquele dia nunca foi somada) · hetzner-occupancy.state.json (baseline de CPU e contadores) · hetzner-occupancy.lock.
  Arquivo corrompido não some: a cópia fica em <arquivo>.corrupt-<epoch>.
USO      hetzner-occupancy-watch.py [--print] [--dry-run] [--print-config]
         exit 0 ok (inclui "outra instância rodando") · 1 crash (traceback no stderr) · 3 não consegui gravar
"""
import argparse
import calendar
import errno
import fcntl
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
LIVE = frozenset({"active", "awake"})  # = bead_state.LIVE_SESSION_STATES
DEAD = frozenset({"asleep", "drained", "closed", "archived", "quarantined", "failed-create"})  # = bead_state.DEAD_SESSION_STATES
WARMUP = frozenset({"sem-leitura-anterior", "leitura-anterior-velha", "contador-recuou", "relogio-recuou"})  # a CPU só semeou o baseline: não é "cego"
BEGIN, END = "@@OCC-BEGIN@@", "@@OCC-END@@"
REMOTE_CMD = "echo %s; grep '^cpu' /proc/stat; echo %s" % (BEGIN, END)
RULE = 2  # a regra que produziu a leitura (vai no JSONL como "regra"): 2 = ocupado é sessão que SEGURA bead (ga-l9q18u); leitura sem o campo é da regra 1, em que sessão viva bastava


class Fail(Exception):
    def __init__(self, msg, rc=3):
        Exception.__init__(self, msg)
        self.rc = rc


# ---- configuração ------------------------------------------------------------------------------------------------------------------------------------
def _num(env, key, default, cast, lo):
    v = cast(env.get(key, default))
    if not v >= lo:  # NaN também reprova
        raise ValueError("%s=%r abaixo do mínimo %r" % (key, v, lo))
    return v


def _names(env, key, default, allow_empty=False):
    out = [s.strip() for s in env.get(key, default).split(",") if s.strip()]
    if not out and not allow_empty:
        raise ValueError("%s vazio" % key)
    return out


def load_config(env):
    city = env.get("GC_CITY_PATH") or DEFAULT_CITY
    home = env.get("HOME") or os.path.expanduser("~")
    interval = _num(env, "HETZNER_OCC_INTERVAL_S", 900, int, 60)
    c = SimpleNamespace(
        city=city, gc_dir=os.path.join(city, ".gc"), interval_s=interval,
        busy_cores=_num(env, "HETZNER_OCC_BUSY_CORES", 0.5, float, 0.01),
        stores=_names(env, "HETZNER_OCC_STORES", "hq"),
        other_hosts=_names(env, "HETZNER_OCC_OTHER_HOSTS", "mbp", True),
        ssh_host=env.get("HETZNER_SSH_HOST", "hetzner-teste"),
        idle_after_s=_num(env, "HETZNER_OCC_IDLE_AFTER_S", 1800, int, 60),
        blind_after_s=_num(env, "HETZNER_OCC_BLIND_AFTER_S", 3600, int, 60),
        slack_s=120,  # o launchd não é relógio suíço: 3 leituras a 890 s ainda são "30 min"
        idle_cooldown_s=_num(env, "HETZNER_OCC_IDLE_COOLDOWN_S", 10800, int, 0),
        blind_cooldown_s=_num(env, "HETZNER_OCC_BLIND_COOLDOWN_S", 21600, int, 0),
        low_pct=_num(env, "HETZNER_OCC_LOW_PCT", 85, float, 0),  # 0 = nenhuma janela é baixa = aviso de CPU baixa desligado
        low_after_s=_num(env, "HETZNER_OCC_LOW_AFTER_S", 1800, int, 60), low_cooldown_s=_num(env, "HETZNER_OCC_LOW_COOLDOWN_S", 10800, int, 0),
        min_window_s=120, max_window_s=3 * interval, future_tol_s=60,
        ssh_timeout_s=_num(env, "HETZNER_OCC_SSH_TIMEOUT_S", 30, int, 1),
        gc_timeout_s=_num(env, "HETZNER_OCC_GC_TIMEOUT_S", 60, int, 1), bd_timeout_s=_num(env, "HETZNER_OCC_BD_TIMEOUT_S", 60, int, 1),
        focus_stale_s=_num(env, "GATE_FOCUS_STALE_S", 7200, int, 1),
        pilot_file=env.get("HETZNER_OCC_PILOT_FILE") or os.path.join(home, ".gc", "pilot-dispatchable.json"),
        gc_bin=env.get("GC_BIN", "gc"), ssh_bin=env.get("SSH_BIN", "ssh"), bd_bin=env.get("BD_BIN", "bd"),
        now=_now(env),
    )
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", c.ssh_host):
        raise ValueError("HETZNER_SSH_HOST inválido: %r" % c.ssh_host)
    if c.low_pct > 100:  # acima de 100 toda janela seria "baixa": o aviso sairia a cada cooldown para sempre (inf também cai aqui; NaN já reprovou no _num)
        raise ValueError("HETZNER_OCC_LOW_PCT=%r acima de 100" % c.low_pct)
    c.alarm_key = os.path.join(c.gc_dir, "hetzner-occupancy-alarm.on")
    c.alarm = env.get("HETZNER_OCC_ALARM") != "0" and os.path.exists(c.alarm_key)  # chave ilegível/ausente = desligado (o estado inerte)
    return c


def _now(env):
    raw = env.get("HETZNER_OCC_NOW", "").strip()
    return int(raw) if raw else int(time.time())


# ---- processos e arquivos ----------------------------------------------------------------------------------------------------------------------------
def run_cmd(argv, timeout):
    """(rc, stdout, stderr, porque). porque: None = rodou até o fim · 'timeout' (o grupo de processos inteiro morre) · 'nao-executou'."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="replace", start_new_session=True)
    except OSError as e:
        return None, "", str(e), "nao-executou"
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=5)
        except Exception:
            pass
        return None, "", "", "timeout"
    return p.returncode, out, err, None


def _failed(rc, why, prefix):
    """'<prefix>-timeout' / '<prefix>-falhou' se o comando não deu certo; None se rodou e saiu 0."""
    if why == "timeout":
        return prefix + "-timeout"
    return prefix + "-falhou" if (why or rc != 0) else None


def _oneline(s, n=160):
    return " ".join((s or "").split())[:n]


def load_json(path, valid, now, dry):
    """O objeto lido, ou None (ausente ou corrompido). Corrompido: a cópia fica em <arquivo>.corrupt-<epoch> (menos no --dry-run) e o stderr avisa."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Fail("não consegui ler %s: %s" % (path, e))
    try:
        obj = json.loads(raw.decode("utf-8"))
        if valid(obj):
            return obj
    except ValueError:  # JSONDecodeError e UnicodeDecodeError
        pass
    dest, n = "%s.corrupt-%d" % (path, now), 1
    while os.path.exists(dest):
        n += 1
        dest = "%s.corrupt-%d-%d" % (path, now, n)
    if not dry:
        try:
            os.replace(path, dest)
        except OSError as e:
            raise Fail("não consegui gravar a cópia de %s: %s" % (path, e))
    print("hetzner-occupancy-watch: AVISO: %s estava corrompido; %s %s" % (path, "a cópia ficou em" if not dry else "(--dry-run) a cópia iria para", dest), file=sys.stderr)
    return None


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise Fail("não consegui gravar %s: %s" % (path, e))


def append_line(path, line):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except OSError as e:
        raise Fail("não consegui gravar %s: %s" % (path, e))


def take_lock(gc_dir):
    """fd do travamento; None se outra instância já o tem. Não conseguir nem abrir o arquivo = Fail (rc 3)."""
    try:
        os.makedirs(gc_dir, exist_ok=True)
        fd = os.open(os.path.join(gc_dir, "hetzner-occupancy.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:
        raise Fail("não consegui gravar em %s: %s" % (gc_dir, e))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return None
        raise Fail("não consegui travar %s: %s" % (gc_dir, e))
    return fd


# ---- leitura 1: sessões remotas ----------------------------------------------------------------------------------------------------------------------
def _ident(s):
    if not isinstance(s, dict):
        return None
    for k in ("session_name", "name", "template"):
        if isinstance(s.get(k), str) and s[k]:
            return s[k]
    return None


def _owners(s):
    """Os nomes pelos quais uma bead in_progress aponta para a sessão: o Pilot atribui ao ALIAS do pool (dog-remote-2); session_name e name também valem."""
    return [s[k] for k in ("session_name", "name", "alias") if isinstance(s.get(k), str) and s[k]]


def read_holders(c):
    """(donos, None, None) ou (None, motivo, detalhe). donos = os assignees das beads in_progress: a sessão que segura uma delas é a que trabalha. Uma leitura, só `list`."""
    # vazio → lista [] = ninguém segura bead (leu); falhou/ilegível/travou → (None, motivo): o chamador deixa 'ocupadas' null e a sessão viva não prova nada (nunca "ocioso")
    rc, out, err, why = run_cmd([c.bd_bin, "-C", c.city, "list", "--status", "in_progress", "--json", "--limit", "0"], c.bd_timeout_s)
    motivo = _failed(rc, why, "bd")
    if motivo:
        return None, motivo, _oneline(err)
    try:
        lst = json.loads(out)
    except ValueError:
        return None, "json-ilegivel" if out.strip() else "saida-vazia", ""
    if not isinstance(lst, list) or not all(isinstance(b, dict) and (b.get("assignee") is None or isinstance(b["assignee"], str)) for b in lst):
        return None, "forma-desconhecida", ""
    return {b["assignee"] for b in lst if b.get("assignee")}, None, None


def read_sessions(c):
    r = {"lido": False, "ativas": None, "ocupadas": None, "nomes": [], "nomes_ocupadas": [], "motivo": None}
    rc, out, err, why = run_cmd([c.gc_bin, "--city", c.city, "session", "list", "--json"], c.gc_timeout_s)
    r["motivo"] = _failed(rc, why, "gc")
    if r["motivo"]:
        r["detalhe"] = _oneline(err)
        return r
    try:
        d = json.loads(out)
    except ValueError:
        r["motivo"] = "json-ilegivel" if out.strip() else "saida-vazia"
        return r
    if isinstance(d, dict) and "ok" in d and d["ok"] is not True:  # envelope de erro ({"ok":false,...}): a lista que vier junto não vale (a regra do worktree-reaper)
        r["motivo"] = "ok-falso"
        return r
    lst = d.get("sessions") if isinstance(d, dict) else None
    if not isinstance(lst, list):
        r["motivo"] = "sem-lista-sessions"
        return r
    other = re.compile(r"-remote-(%s)(-|$)" % "|".join(re.escape(h) for h in c.other_hosts)) if c.other_hosts else None
    active, live, bad_entry, bad_state = [], [], 0, 0
    for s in lst:
        ident = _ident(s)
        if ident is None:
            bad_entry += 1
        elif "-remote-" not in "-%s-" % ident or (other and other.search(ident)):
            continue  # sessão local, ou de outro host remoto: não é ocupação do Hetzner
        elif s.get("closed"):
            continue
        elif isinstance(s.get("state"), str) and s["state"] in LIVE:
            active.append(ident)
            live.append((ident, _owners(s)))
        elif not (isinstance(s.get("state"), str) and s["state"] in DEAD):
            bad_state += 1  # state ausente ou fora do vocabulário (draining, start-pending...): não dá para dizer que trabalha nem que dorme
    if bad_entry + bad_state:
        r["ilegiveis"] = bad_entry + bad_state
    unreadable = "entrada-ilegivel" if bad_entry else "estado-ilegivel"
    if not active:
        if bad_entry or bad_state:
            r["motivo"] = unreadable
        else:
            r.update(lido=True, ativas=0, ocupadas=0)  # nenhuma viva: o bd nem é chamado (e o Dolt fora do ar não atrapalha)
        return r
    r.update(ativas=len(active), nomes=sorted(active))  # o gc leu: as vivas contam mesmo que o bd falhe, mas viva não é ocupada
    held, why, detail = read_holders(c)
    if held is None:
        r["motivo"], r["detalhe"] = why, detail  # ocupadas fica null (não 0): não sei quem segura bead
        return r
    mine = sorted(i for i, owners in live if held.intersection(owners))
    r.update(ocupadas=len(mine), nomes_ocupadas=mine)
    if mine:  # uma sessão que segura bead provada basta, mesmo com entrada ilegível ou sem nome ao lado
        r["lido"] = True
    elif bad_entry or bad_state:
        r["motivo"] = unreadable  # a ilegível pode ser a que trabalha
    elif any(not owners for _i, owners in live):
        r["motivo"] = "sessao-sem-dono"  # viva sem session_name, alias nem name: não dá para casar com bead
    else:
        r["lido"] = True
    return r


# ---- leitura 2: CPU do nó (/proc/stat por ssh) -------------------------------------------------------------------------------------------------------
def parse_stat(out):
    """((busy, total, ncpu), None) ou (None, motivo). busy = user+nice+system+irq+softirq; total = os 8 primeiros campos (guest já está em user)."""
    lines = [ln.strip() for ln in out.splitlines()]
    if BEGIN not in lines or END not in lines[lines.index(BEGIN) + 1:]:
        return None, "sem-marcador"
    i = lines.index(BEGIN)
    body = lines[i + 1:lines.index(END, i + 1)]
    agg, ncpu = None, 0
    for ln in body:
        f = ln.split()
        if f and f[0] == "cpu":
            agg = f
        elif f and re.fullmatch(r"cpu[0-9]+", f[0]):
            ncpu += 1
    try:
        v = [int(x) for x in agg[1:9]] if agg else []
    except ValueError:
        v = []
    if len(v) < 8 or min(v) < 0:
        return None, "linha-cpu-ilegivel"
    if ncpu == 0:
        return None, "sem-nucleos"
    total = sum(v)
    return (total - v[3] - v[4] - v[7], total, ncpu), None


def _baseline_ok(b):
    return isinstance(b, dict) and all(isinstance(b.get(k), int) and not isinstance(b.get(k), bool) and b[k] >= 0 for k in ("epoch", "busy", "total"))


def read_cpu(c, base, now):
    """(cpu, novo_baseline|None, núcleos). novo_baseline None = manter o antigo; a falha de leitura NUNCA apaga o baseline."""
    cpu = {"lido": False, "nucleos": None, "ncpu": None, "janela_s": None, "pct": None, "motivo": None}
    argv = [c.ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", c.ssh_host, REMOTE_CMD]
    rc, out, err, why = run_cmd(argv, c.ssh_timeout_s)
    cpu["motivo"] = _failed(rc, why, "ssh")
    if cpu["motivo"]:
        cpu["detalhe"] = _oneline(err)
        return cpu, None, None
    got, cpu["motivo"] = parse_stat(out)
    if got is None:
        return cpu, None, None
    busy, total, ncpu = got
    cpu["ncpu"] = ncpu
    now_b = {"epoch": now, "busy": busy, "total": total}
    if not _baseline_ok(base):
        cpu["motivo"] = "sem-leitura-anterior"
        return cpu, now_b, None
    win = now - base["epoch"]
    cpu["janela_s"] = win
    if win < 0:
        cpu["motivo"] = "relogio-recuou"
        return cpu, now_b, None
    if win < c.min_window_s:
        cpu["motivo"] = "janela-curta"
        return cpu, None, None
    if win > c.max_window_s:
        cpu["motivo"] = "leitura-anterior-velha"
        return cpu, now_b, None
    db, dt = busy - base["busy"], total - base["total"]
    if db < 0 or dt < 0:
        cpu["motivo"] = "contador-recuou"
        return cpu, now_b, None
    if dt == 0:
        cpu["motivo"] = "sem-tick"
        return cpu, None, None
    cores = db * ncpu / dt
    cpu.update(lido=True, nucleos=round(cores, 2), pct=round(100.0 * db / dt, 1), motivo=None)
    return cpu, now_b, cores


# ---- leitura 3: fila do Pilot e foco do gate ---------------------------------------------------------------------------------------------------------
def _iso_epoch(s):
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def read_queue(c, now):
    r = {"lido": False, "n": None, "ids": [], "motivo": None}
    try:
        with open(c.pilot_file, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        r["motivo"] = "arquivo-ausente"
        return r
    except (OSError, ValueError):
        r["motivo"] = "arquivo-ilegivel"
        return r
    items = d.get("items") if isinstance(d, dict) else None
    if not isinstance(items, list):
        r["motivo"] = "forma-desconhecida"
        return r
    gen, ttl = _iso_epoch(d.get("generated_at")), d.get("ttl_seconds")
    if gen is None:
        r["motivo"] = "generated_at-ilegivel"
    elif isinstance(ttl, bool) or not isinstance(ttl, (int, float)):
        r["motivo"] = "sem-ttl"
    elif now - gen > ttl:
        r["motivo"] = "velho"  # só passa do ttl é velho (mesma conta do approved-state-reconciler)
    elif now - gen < -c.future_tol_s:
        r["motivo"] = "no-futuro"
    elif not all(isinstance(it, dict) and isinstance(it.get("store"), str) for it in items):
        r["motivo"] = "forma-desconhecida"
    if r["motivo"]:
        return r
    elig = [str(it.get("id", "?")) for it in items if it["store"] in c.stores]
    r.update(lido=True, n=len(elig), ids=elig[:5])
    return r


def read_focus(c, now):
    """ligado / desligado / desconhecido: a mesma regra de gate_focus_active (gate-focus-lib.sh); desconhecido avisa como se estivesse desligado."""
    kv = {}
    try:
        with open(os.path.join(c.gc_dir, "gate-focus.state"), encoding="utf-8") as f:
            for ln in f:
                k, sep, v = ln.rstrip("\n").partition("=")
                if sep and k not in kv:
                    kv[k] = v
    except (OSError, ValueError):
        return "desconhecido"
    active, at = kv.get("active"), kv.get("at", "")
    if active not in ("0", "1") or not re.fullmatch(r"[0-9]+", at):
        return "desconhecido"
    if now - int(at) > c.focus_stale_s or int(at) > now + 60:
        return "desconhecido"
    return "ligado" if active == "1" else "desligado"


# ---- estado, sequências e aviso ----------------------------------------------------------------------------------------------------------------------
def decide(sess, cpu, cores, busy_cores):
    if (sess["lido"] and sess["ocupadas"]) or (cpu["lido"] and cores >= busy_cores):
        return "ocupado"
    if sess["lido"] and cpu["lido"]:
        return "ocioso"
    return "desconhecido"


def _int(v, default=None):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else default


def _flt(v, default=None):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0 else default


def _mins(s):
    return int(round(s / 60.0))


def _avg_pct(nucleos_s, capacidade_s):
    """% da capacidade usada: núcleos-segundo ocupados / núcleos-segundo disponíveis. Sem capacidade medida é None (não 0 %: ninguém mediu)."""
    return round(100.0 * nucleos_s / capacidade_s, 1) if capacidade_s else None


def _show(v, none="não lido"):
    return none if v is None else str(v)


def low_streak(c, st, cpu, cores, now):
    """A sequência de janelas de CPU seguidas, cada uma com média abaixo da régua: {n, desde, nucleos_s, cap_s}. n = 0 = sem sequência. `desde` é o INÍCIO da janela da 1ª (a CPU é
    uma média sobre a janela inteira, então 2 janelas de 15 min = 30 min medidos). Só uma janela LIDA entra: CPU ilegível ou alta zera, nunca estende."""
    if not (cpu["lido"] and cpu["pct"] < c.low_pct):
        return {"n": 0, "desde": None, "nucleos_s": None, "cap_s": None}
    win_n, win_c = cores * cpu["janela_s"], cpu["ncpu"] * cpu["janela_s"]
    # vazio → sem sequência anterior (recomeça aqui); falhou/ilegível/no futuro (estado editado à mão, relógio que recuou) → recomeça aqui também: nunca SOMA um número que não confere (a janela de agora vale por si, medida pelos contadores)
    prev_n, since, acc_n, acc_c = _int(st.get("baixas_seguidas"), 0), _int(st.get("baixa_desde")), _flt(st.get("baixa_nucleos_s")), _flt(st.get("baixa_capacidade_s"))
    if prev_n > 0 and since is not None and since <= now and acc_n is not None and acc_c is not None:
        return {"n": prev_n + 1, "desde": since, "nucleos_s": acc_n + win_n, "cap_s": acc_c + win_c}
    return {"n": 1, "desde": now - cpu["janela_s"], "nucleos_s": win_n, "cap_s": win_c}


def migrate_daily(daily):
    """Dia gravado antes da ga-2hd02v.6 (sem cpu_janelas): o `ocupacao_pct` dele é o número de SESSÃO. Ele passa a se chamar ocupacao_sessao_pct e `ocupacao_pct` (a média de CPU) fica null:
    a CPU daquele dia nunca foi somada, e um número de sessão com cara de CPU seria pior que nenhum. Uma vez só: depois da 1ª passada o dia tem cpu_janelas."""
    for day in daily["dias"].values():
        if isinstance(day, dict) and "cpu_janelas" not in day:
            if "ocupacao_pct" in day and "ocupacao_sessao_pct" not in day:
                day["ocupacao_sessao_pct"] = day["ocupacao_pct"]
            day.update(ocupacao_pct=None, cpu_janelas=0, cpu_nucleos_s=0.0, cpu_capacidade_s=0)


def idle_mail(c, rd, span):
    fila, sess, cpu = rd["fila"], rd["sessoes"], rd["cpu"]
    foco = rd["foco"] + (" (tratado como desligado)" if rd["foco"] == "desconhecido" else "")
    subj = "Hetzner ocioso há %d min com %d bead(s) aprovada(s) na fila" % (_mins(span), fila["n"])
    body = "\n".join([
        "Estado do mundo: o nó Hetzner (%s) está OCIOSO há %d min (%d leituras seguidas, a cada %d min) e o Pilot tem %d bead(s) aprovada(s) esperando. "
        "Regra do Athos (14/10): o Hetzner pago trabalha sempre." % (c.ssh_host, _mins(span), rd["ociosas_seguidas"], _mins(c.interval_s), fila["n"]),
        "• sessões remotas vivas: %s · segurando bead: %s · CPU: %s núcleo(s) ocupado(s) de %s na última janela de %s s (régua: %s)" % (
            sess["ativas"], sess["ocupadas"], cpu["nucleos"], cpu["ncpu"], cpu["janela_s"], c.busy_cores),
        "• fila (até %d; primeiros ids): %s" % (fila["n"], ", ".join(fila["ids"])),
        "• foco do gate: " + foco,
        "A fila é lida do pilot-dispatchable.json ANTES dos vetos de pool e do freio de top-up: parte dela pode estar vetada, então o número é um teto, não uma promessa.",
        "O vigia só mede e avisa: não atribui nem despacha nada. Próximo aviso deste tipo em no mínimo %d h. Voltar a só-medir: rm %s" % (c.idle_cooldown_s // 3600, c.alarm_key),
    ])
    return subj, body


def blind_mail(c, rd, span, cpu_span=None):
    """span = minutos sem leitura que decidisse o ESTADO (None = o estado não está cego); cpu_span = minutos sem ler a CPU (None = a CPU está lida). Pelo menos um dos dois."""
    sess, cpu, fila = rd["sessoes"], rd["cpu"], rd["fila"]
    subj = "Hetzner: vigia de ocupação CEGO há %d min (não consigo medir)" % _mins(max(s for s in (span, cpu_span) if s is not None))
    lines = []
    if span is not None:
        lines.append("Estado do mundo: há %d min (%d leituras) o vigia não consegue dizer se o nó Hetzner está ocioso ou ocupado. Enquanto isso NENHUM aviso de ocioso sai "
                     "(leitura que falha nunca vira \"ocioso\")." % (_mins(span), rd["cegas_seguidas"]))
    if cpu_span is not None:
        lines.append("%s há %d min (%d leituras) o vigia não consegue ler a CPU do nó Hetzner. Enquanto isso o aviso de CPU baixa NÃO sai (leitura que falha nunca vira \"CPU baixa\"), "
                     "mesmo que uma sessão segurando bead mantenha o estado em \"ocupado\"." % ("Estado do mundo:" if span is None else "E", _mins(cpu_span), rd["cpu_cegas_seguidas"]))
    body = "\n".join(lines + [
        "• sessões: %s · CPU: %s · fila: %s" % (sess["motivo"] or "ok", cpu["motivo"] or "ok", fila["motivo"] or "ok"),
        "• detalhe: %s" % (_oneline(sess.get("detalhe", "") + " " + cpu.get("detalhe", ""), 200) or "-"),
        "Conferir no mini: a lista de sessões do gc, o ssh %s e a idade do ~/.gc/pilot-dispatchable.json. Próximo aviso deste tipo em no mínimo %d h." % (c.ssh_host, c.blind_cooldown_s // 3600),
    ])
    return subj, body


def low_mail(c, rd, low):
    fila, sess, cpu = rd["fila"], rd["sessoes"], rd["cpu"]
    span, media = rd["epoch"] - low["desde"], _avg_pct(low["nucleos_s"], low["cap_s"])
    foco = rd["foco"] + (" (tratado como desligado)" if rd["foco"] == "desconhecido" else "")
    subj = "Hetzner abaixo da meta: CPU média de %s%% há %d min (aviso abaixo de %g%%)" % (media, _mins(span), c.low_pct)
    body = "\n".join([
        "Estado do mundo: a CPU do nó Hetzner (%s) está abaixo de %g%% há %d min (%d janelas seguidas de CPU): média de %s%%. Meta do Athos (20/10): o nó pago fica com a CPU perto de 100%% o tempo todo."
        % (c.ssh_host, c.low_pct, _mins(span), low["n"], media),
        "• última janela: %s%% (%s núcleo(s) de %s ocupados, janela de %s s)" % (cpu["pct"], cpu["nucleos"], cpu["ncpu"], cpu["janela_s"]),
        "• contexto (não entra na decisão): sessões remotas vivas: %s · segurando bead: %s · fila do Pilot (hq): %s · foco do gate: %s" % (
            _show(sess["ativas"]), _show(sess["ocupadas"]), _show(fila["n"], "não lida"), foco),
        "Este aviso NÃO depende de fila nem de sessão: com sessão segurando bead e a CPU parada ele sai do mesmo jeito (foi o que faltou na madrugada de 20/10, 7 h com 0 a 15% de CPU e zero aviso). "
        "A fila, quando lida, é a do Pilot ANTES dos vetos de pool e do freio de top-up: é um teto, não uma promessa.",
        "O vigia só mede e avisa: não atribui nem despacha nada. Próximo aviso deste tipo em no mínimo %d h. Voltar a só-medir: rm %s" % (c.low_cooldown_s // 3600, c.alarm_key),
    ])
    return subj, body


def send_mail(c, subj, body):
    rc, _o, _e, why = run_cmd([c.gc_bin, "--city", c.city, "mail", "send", "mayor", "-s", subj, "-m", body], 45)
    return why is None and rc == 0


def _plan(c, due, last_at, cooldown_s, now, dry, silent=None):
    if not due:
        return "nao"
    if not c.alarm:
        return "desligado"
    if silent:
        return silent
    if last_at is not None and 0 <= now - last_at < cooldown_s:
        return "cooldown"
    return "enviaria" if dry else "enviar"


def run(args, env):
    c = load_config(env)
    if args.print_config:
        keys = ("city", "interval_s", "busy_cores", "stores", "other_hosts", "ssh_host", "alarm", "alarm_key", "idle_after_s", "blind_after_s", "slack_s",
                "idle_cooldown_s", "blind_cooldown_s", "low_pct", "low_after_s", "low_cooldown_s", "min_window_s", "max_window_s", "ssh_timeout_s", "gc_timeout_s", "bd_timeout_s", "pilot_file")
        print(json.dumps({k: getattr(c, k) for k in keys}, ensure_ascii=False, indent=2))
        return 0
    now, dry = c.now, args.dry_run
    if not dry and take_lock(c.gc_dir) is None:
        print("hetzner-occupancy-watch: outra instância ainda está rodando; saio sem medir (o lock é do kernel e some sozinho)", file=sys.stderr)
        return 0
    state_path = os.path.join(c.gc_dir, "hetzner-occupancy.state.json")
    st = load_json(state_path, lambda o: isinstance(o, dict), now, dry) or {}

    sess = read_sessions(c)
    cpu, new_base, cores = read_cpu(c, st.get("cpu"), now)
    fila, foco = read_queue(c, now), read_focus(c, now)
    est = decide(sess, cpu, cores, c.busy_cores)

    decided = est == "ocupado" or (est == "ocioso" and fila["lido"])
    warm = est == "desconhecido" and sess["lido"] and cpu["motivo"] in WARMUP
    prev_ocio = _int(st.get("ociosas_seguidas"), 0)
    ocio = prev_ocio + 1 if est == "ocioso" else 0
    ocio_desde = (_int(st.get("ocioso_desde"), now) if prev_ocio > 0 else now) if est == "ocioso" else None
    cegas = 0 if decided else _int(st.get("cegas_seguidas"), 0) + (0 if warm else 1)
    decidida_em = now if decided else _int(st.get("decidida_em"), now)  # sem nenhuma decidida ainda, conta desde a 1ª leitura
    # a CPU cega é outra conta: uma sessão que prova "ocupado" decide o ESTADO, mas com a CPU ilegível o aviso de CPU baixa não tem como sair (ga-2hd02v.6)
    cpu_warm = not cpu["lido"] and cpu["motivo"] in WARMUP
    cpu_cegas = 0 if cpu["lido"] else _int(st.get("cpu_cegas_seguidas"), 0) + (0 if cpu_warm else 1)
    cpu_lida_em = now if cpu["lido"] else _int(st.get("cpu_lida_em"), now)  # sem nenhuma lida ainda, conta desde a 1ª leitura
    low = low_streak(c, st, cpu, cores, now)

    rd = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), "epoch": now, "regra": RULE, "estado": est, "sessoes": sess, "cpu": cpu, "fila": fila, "foco": foco,
          "ociosas_seguidas": ocio, "cegas_seguidas": cegas, "baixas_seguidas": low["n"], "cpu_cegas_seguidas": cpu_cegas}
    idle_due = est == "ocioso" and fila["lido"] and fila["n"] > 0 and now - ocio_desde >= c.idle_after_s - c.slack_s
    blind_state_due = cegas > 0 and now - decidida_em >= c.blind_after_s - c.slack_s
    blind_cpu_due = cpu_cegas > 0 and now - cpu_lida_em >= c.blind_after_s - c.slack_s
    blind_due = blind_state_due or blind_cpu_due
    low_due = low["n"] > 0 and now - low["desde"] >= c.low_after_s - c.slack_s
    last_idle, last_blind, last_low = _int(st.get("alarme_ocioso_em")), _int(st.get("alarme_cego_em")), _int(st.get("alarme_baixa_em"))
    a_idle = _plan(c, idle_due, last_idle, c.idle_cooldown_s, now, dry, "foco" if foco == "ligado" else None)
    a_blind = _plan(c, blind_due, last_blind, c.blind_cooldown_s, now, dry)
    a_low = _plan(c, low_due, last_low, c.low_cooldown_s, now, dry)
    rd["alarme"] = {"ocioso": a_idle, "cego": a_blind, "cpu_baixa": a_low}
    if dry:
        rd["dry_run"] = True

    new_st = {"versao": 1, "cpu": new_base or (st.get("cpu") if _baseline_ok(st.get("cpu")) else None), "ociosas_seguidas": ocio, "ocioso_desde": ocio_desde,
              "cegas_seguidas": cegas, "decidida_em": decidida_em, "alarme_ocioso_em": last_idle, "alarme_cego_em": last_blind, "atualizado_em": now,
              "cpu_cegas_seguidas": cpu_cegas, "cpu_lida_em": cpu_lida_em, "baixas_seguidas": low["n"], "baixa_desde": low["desde"],
              "baixa_nucleos_s": None if low["n"] == 0 else round(low["nucleos_s"], 2), "baixa_capacidade_s": None if low["n"] == 0 else low["cap_s"], "alarme_baixa_em": last_low}
    sends = []  # (chave do estado, valor antigo, assunto, corpo)
    if a_idle == "enviar":
        sends.append(("alarme_ocioso_em", last_idle, ("ocioso",)) + idle_mail(c, rd, now - ocio_desde))
    if a_blind == "enviar":
        sends.append(("alarme_cego_em", last_blind, ("cego",)) + blind_mail(c, rd, now - decidida_em if blind_state_due else None, now - cpu_lida_em if blind_cpu_due else None))
    if a_low == "enviar":
        sends.append(("alarme_baixa_em", last_low, ("cpu_baixa",)) + low_mail(c, rd, low))
    if not dry:
        for key, _old, _k, _s, _b in sends:
            new_st[key] = now  # o cooldown é gravado ANTES do mail: se não der para gravar, o mail nem sai (nada de repetir a cada rodada)
        write_atomic(state_path, json.dumps(new_st, ensure_ascii=False, sort_keys=True, indent=1))
        failed = False
        for key, old, (kind,), subj, body in sends:
            ok = send_mail(c, subj, body)
            rd["alarme"][kind] = "enviado" if ok else "falhou"
            if not ok:
                new_st[key], failed = old, True  # mail que falha não gasta o cooldown: a próxima rodada tenta de novo
        if failed:
            write_atomic(state_path, json.dumps(new_st, ensure_ascii=False, sort_keys=True, indent=1))
        append_line(os.path.join(c.gc_dir, "hetzner-occupancy.jsonl"), json.dumps(rd, ensure_ascii=False, separators=(",", ":")))
        daily_path = os.path.join(c.gc_dir, "hetzner-occupancy-daily.json")
        daily = load_json(daily_path, lambda o: isinstance(o, dict) and isinstance(o.get("dias"), dict), now, dry) or {"dias": {}}
        migrate_daily(daily)
        day = daily["dias"].setdefault(time.strftime("%Y-%m-%d", time.localtime(now)), {"ocupado": 0, "ocioso": 0, "desconhecido": 0, "leituras": 0, "ocupacao_pct": None, "ocupacao_sessao_pct": None,
                                                                                         "cpu_janelas": 0, "cpu_nucleos_s": 0.0, "cpu_capacidade_s": 0})
        day[est] += 1
        day["leituras"] += 1
        dec = day["ocupado"] + day["ocioso"]
        day["ocupacao_sessao_pct"] = round(100.0 * day["ocupado"] / dec, 1) if dec else None
        if cpu["lido"]:  # só janela LIDA entra na média de CPU do dia; sem nenhuma, ocupacao_pct fica null (nunca 0 %)
            day["cpu_janelas"] += 1
            day["cpu_nucleos_s"] = round(day["cpu_nucleos_s"] + cores * cpu["janela_s"], 2)
            day["cpu_capacidade_s"] += cpu["ncpu"] * cpu["janela_s"]
        day["ocupacao_pct"] = _avg_pct(day["cpu_nucleos_s"], day["cpu_capacidade_s"])
        daily["intervalo_s"] = c.interval_s
        write_atomic(daily_path, json.dumps(daily, ensure_ascii=False, sort_keys=True, indent=1))
    if args.show:
        print(json.dumps(rd, ensure_ascii=False, indent=2))
    else:
        print("%s estado=%s sessoes=%s cpu=%s fila=%s foco=%s ociosas=%d cegas=%d alarme=%s/%s/%s" % (
            rd["ts"], est, sess["ativas"], cpu["nucleos"], fila["n"], foco, ocio, cegas, rd["alarme"]["ocioso"], rd["alarme"]["cego"], rd["alarme"]["cpu_baixa"]))
    return 0


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="vigia de ocupação do nó Hetzner (ga-2hd02v.1.12)")
    ap.add_argument("--print", dest="show", action="store_true", help="imprime a leitura (JSON) em vez do resumo de uma linha")
    ap.add_argument("--dry-run", action="store_true", help="lê tudo e mostra o que faria; não grava nada nem manda mail")
    ap.add_argument("--print-config", action="store_true", help="imprime a configuração em vigor e sai")
    args = ap.parse_args(argv)
    try:
        return run(args, os.environ)
    except Fail as e:
        print("hetzner-occupancy-watch: %s" % e, file=sys.stderr)
        return e.rc
    except Exception:  # inclui configuração inválida: o traceback fica à vista no log do launchd
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
