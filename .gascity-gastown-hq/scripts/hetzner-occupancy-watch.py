#!/usr/bin/env python3
"""hetzner-occupancy-watch.py — o nó Hetzner pago está trabalhando? Uma leitura a cada 15 min e o número de ocupação por dia. (ga-2hd02v.1.12)

Contents
  Regra · Estado · Arquivos · Uso

REGRA (Athos, 14/10): "Hetzner pago trabalha sempre". O launchd do mini roda isto a cada 900 s (com.gascity.hetzner-occupancy-watch). Cada rodada faz DUAS
leituras, e cada uma tem três estados (leu / não consegui ler / vale X): "não consegui" nunca vira "ocioso" nem "ocupado".
  sessões  `gc session list --json`: sessões com `-remote-` no nome em state active/awake (as de `-remote-mbp-` são de outro host e não contam)
  CPU      `ssh hetzner-teste` lê o /proc/stat: núcleos ocupados NA JANELA desde a leitura anterior (uma rajada entre duas leituras aparece; um instante não vale)
ESTADO   ocupado = sessão remota ativa OU CPU >= régua (0,5 núcleo, HETZNER_OCC_BUSY_CORES): uma prova basta
         ocioso  = sessões e CPU lidas e as duas dizem ocioso
         desconhecido = o resto (inclui a 1ª leitura, que só semeia o baseline de CPU)
         Este vigia só MEDE e grava em <cidade>/.gc: não manda mail, não avisa ninguém, não atribui nem despacha nada. O aviso ao Mayor é a fatia seguinte desta bead.
ARQUIVOS (só em <cidade>/.gc): hetzner-occupancy.jsonl (uma leitura por rodada) · hetzner-occupancy-daily.json (o número por dia: ocupado/ocioso/desconhecido e
  ocupacao_pct = ocupado/(ocupado+ocioso), null se nenhuma leitura decidiu) · hetzner-occupancy.state.json (baseline de CPU) · hetzner-occupancy.lock.
  Arquivo corrompido não some: a cópia fica em <arquivo>.corrupt-<epoch>.
USO      hetzner-occupancy-watch.py [--print] [--dry-run] [--print-config]
         exit 0 ok (inclui "outra instância rodando") · 1 crash (traceback no stderr) · 3 não consegui gravar
"""
import argparse
import errno
import fcntl
import json
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
BEGIN, END = "@@OCC-BEGIN@@", "@@OCC-END@@"
REMOTE_CMD = "echo %s; grep '^cpu' /proc/stat; echo %s" % (BEGIN, END)


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


def _names(env, key, default):
    return [s.strip() for s in env.get(key, default).split(",") if s.strip()]


def load_config(env):
    city = env.get("GC_CITY_PATH") or DEFAULT_CITY
    interval = _num(env, "HETZNER_OCC_INTERVAL_S", 900, int, 60)
    c = SimpleNamespace(
        city=city, gc_dir=os.path.join(city, ".gc"), interval_s=interval,
        busy_cores=_num(env, "HETZNER_OCC_BUSY_CORES", 0.5, float, 0.01),
        other_hosts=_names(env, "HETZNER_OCC_OTHER_HOSTS", "mbp"),
        ssh_host=env.get("HETZNER_SSH_HOST", "hetzner-teste"),
        min_window_s=120, max_window_s=3 * interval,
        ssh_timeout_s=_num(env, "HETZNER_OCC_SSH_TIMEOUT_S", 30, int, 1),
        gc_timeout_s=_num(env, "HETZNER_OCC_GC_TIMEOUT_S", 60, int, 1),
        gc_bin=env.get("GC_BIN", "gc"), ssh_bin=env.get("SSH_BIN", "ssh"),
        now=_now(env),
    )
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]*", c.ssh_host):
        raise ValueError("HETZNER_SSH_HOST inválido: %r" % c.ssh_host)
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


def read_sessions(c):
    r = {"lido": False, "ativas": None, "nomes": [], "motivo": None}
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
    active, bad_entry, bad_state = [], 0, 0
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
        elif not (isinstance(s.get("state"), str) and s["state"] in DEAD):
            bad_state += 1  # state ausente ou fora do vocabulário (draining, start-pending...): não dá para dizer que trabalha nem que dorme
    if active:  # uma sessão ativa provada basta, mesmo com entradas ilegíveis ao lado
        r.update(lido=True, ativas=len(active), nomes=sorted(active))
    elif bad_entry or bad_state:
        r["motivo"] = "entrada-ilegivel" if bad_entry else "estado-ilegivel"
    else:
        r.update(lido=True, ativas=0)
    if bad_entry + bad_state:
        r["ilegiveis"] = bad_entry + bad_state
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


# ---- estado e execução -------------------------------------------------------------------------------------------------------------------------------
def decide(sess, cpu, cores, busy_cores):
    if (sess["lido"] and sess["ativas"]) or (cpu["lido"] and cores >= busy_cores):
        return "ocupado"
    if sess["lido"] and cpu["lido"]:
        return "ocioso"
    return "desconhecido"


def run(args, env):
    c = load_config(env)
    if args.print_config:
        keys = ("city", "interval_s", "busy_cores", "other_hosts", "ssh_host", "min_window_s", "max_window_s", "ssh_timeout_s", "gc_timeout_s")
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
    est = decide(sess, cpu, cores, c.busy_cores)

    rd = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), "epoch": now, "estado": est, "sessoes": sess, "cpu": cpu}
    if dry:
        rd["dry_run"] = True

    new_st = {"versao": 1, "cpu": new_base or (st.get("cpu") if _baseline_ok(st.get("cpu")) else None), "atualizado_em": now}
    if not dry:
        write_atomic(state_path, json.dumps(new_st, ensure_ascii=False, sort_keys=True, indent=1))
        append_line(os.path.join(c.gc_dir, "hetzner-occupancy.jsonl"), json.dumps(rd, ensure_ascii=False, separators=(",", ":")))
        daily_path = os.path.join(c.gc_dir, "hetzner-occupancy-daily.json")
        daily = load_json(daily_path, lambda o: isinstance(o, dict) and isinstance(o.get("dias"), dict), now, dry) or {"dias": {}}
        day = daily["dias"].setdefault(time.strftime("%Y-%m-%d", time.localtime(now)), {"ocupado": 0, "ocioso": 0, "desconhecido": 0, "leituras": 0, "ocupacao_pct": None})
        day[est] += 1
        day["leituras"] += 1
        dec = day["ocupado"] + day["ocioso"]
        day["ocupacao_pct"] = round(100.0 * day["ocupado"] / dec, 1) if dec else None
        daily["intervalo_s"] = c.interval_s
        write_atomic(daily_path, json.dumps(daily, ensure_ascii=False, sort_keys=True, indent=1))
    if args.show:
        print(json.dumps(rd, ensure_ascii=False, indent=2))
    else:
        print("%s estado=%s sessoes=%s cpu=%s" % (rd["ts"], est, sess["ativas"], cpu["nucleos"]))
    return 0


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="vigia de ocupação do nó Hetzner (ga-2hd02v.1.12)")
    ap.add_argument("--print", dest="show", action="store_true", help="imprime a leitura (JSON) em vez do resumo de uma linha")
    ap.add_argument("--dry-run", action="store_true", help="lê tudo e mostra o que faria; não grava nada")
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
