#!/usr/bin/env python3
"""hetzner-idle-session-reaper.py — fecha a sessão remota do Hetzner que está SEM bead há mais de 15 min. (ga-mu9k7m)

Contents
  Regra · Estado · Arquivos · Uso

PALIATIVO até o patch do engine da ga-2hd02v.1.22 entrar na janela (docs/pending-engine-window/ga-2hd02v.1.22-*.patch): hoje o engine acorda de novo, 1 a 9 min depois,
a sessão manual que o idle_timeout acabou de dormir, e 3 sessões dog-remote vivas sem bead seguram os 3 slots do nó (20/10 06:39 e 13:0x: "sem alias dog-remote-<n> livre").
Quando o patch entrar: descarregar o job (docs/runbooks/hetzner-idle-session-reaper.md) e apagar estes arquivos.
REGRA  o launchd do mini roda isto a cada 600 s (com.gascity.hetzner-idle-session-reaper). Duas leituras, cada uma com três estados (leu / não consegui ler / vale X):
         `gc session list --json`   as sessões dos templates HETZNER_REAP_TEMPLATES (dog-remote, gate-reviewer-remote, kimi-worker-remote), com state e closed
         `bd list --include-infra --status open,in_progress --json --limit 0`   quem SEGURA bead: assignee = o id, o session_name, o name ou o alias da sessão
       "não consegui ler" (qualquer das duas) = ninguém é fechado e o estado nem anda. Bead ABERTA também segura a sessão (a in_progress sozinha não basta).
       kimi-worker-remote (ga-do1ixn.5) entra: a bead dele é do rig gascity, na loja da HQ, como a do dog-remote.
       wa-worker-remote fica de fora de propósito: a bead dele mora na loja da WA, que o bd da HQ não lê; sem provar "sem bead" não se fecha.
ESTADO por sessão (id), em <cidade>/.gc/hetzner-idle-reaper.state.json: `desde` (1ª leitura sem bead, vale também enquanto ela dorme: o laço do engine a faz dormir e acordar)
       e `vivas_seguidas` (rodadas seguidas em que a vi VIVA e sem bead). Uma leitura em que ela segura bead, ou em que sumiu da lista, apaga o relógio.
FECHA  só se: viva (active/awake) · sem bead · agora - desde > 900 s (HETZNER_REAP_GRACE_S) · vivas_seguidas >= 2 (a sessão que o Pilot acabou de acordar para receber bead
       não é fechada na rodada em que a vi) · ninguém anexado · id de verdade (nunca `session close -`) · e o bd, lido DE NOVO logo antes do close, ainda diz sem bead.
       `gc session close <id>` é o fechamento canônico (o mesmo do adhoc-session-reaper). Estado ilegível/corrompido = recomeça do zero (a cópia fica em <arquivo>.corrupt-<epoch>).
ARQUIVOS (em <cidade>/.gc) hetzner-idle-reaper.jsonl (uma linha por sessão fechada, que falhou ao fechar ou que a releitura salvou) · hetzner-occupancy.jsonl (UMA linha
       "tipo":"reaper" por rodada que fechou ou falhou, junto das leituras do vigia de ocupação; o vigia só ESCREVE nesse arquivo) · hetzner-idle-reaper.state.json ·
       hetzner-idle-reaper.lock · hetzner-idle-reaper.off (presente = desligado: não lê nada, não fecha nada).
USO    hetzner-idle-session-reaper.py [--dry-run]       exit 0 ok (inclui "desligado", "não consegui ler" e "outra instância rodando") · 1 crash · 3 não consegui gravar
"""
import argparse
import errno
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
LIVE = frozenset({"active", "awake"})  # = bead_state.LIVE_SESSION_STATES
DEAD = frozenset({"asleep", "drained", "closed", "archived", "quarantined", "failed-create"})  # = bead_state.DEAD_SESSION_STATES


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


def load_config(env):
    city = env.get("GC_CITY_PATH") or DEFAULT_CITY
    raw = env.get("HETZNER_REAP_NOW", "").strip()
    templates = [s.strip() for s in env.get("HETZNER_REAP_TEMPLATES", "dog-remote,gate-reviewer-remote,kimi-worker-remote").split(",") if s.strip()]
    if not templates:
        raise ValueError("HETZNER_REAP_TEMPLATES vazio")
    return SimpleNamespace(
        city=city, gc_dir=os.path.join(city, ".gc"), templates=templates,
        grace_s=_num(env, "HETZNER_REAP_GRACE_S", 900, int, 60), min_live_runs=_num(env, "HETZNER_REAP_MIN_LIVE_RUNS", 2, int, 1),
        gc_timeout_s=_num(env, "HETZNER_REAP_GC_TIMEOUT_S", 60, int, 1), bd_timeout_s=_num(env, "HETZNER_REAP_BD_TIMEOUT_S", 60, int, 1),
        gc_bin=env.get("GC_BIN", "gc"), bd_bin=env.get("BD_BIN", "bd"), now=int(raw) if raw else int(time.time()))


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


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


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
        fd = os.open(os.path.join(gc_dir, "hetzner-idle-reaper.lock"), os.O_RDWR | os.O_CREAT, 0o644)
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


def load_state(path, now, dry):
    """{id: {desde, vivas_seguidas}}. Ausente = {} (1ª rodada). Corrompido = {} e a cópia fica em <arquivo>.corrupt-<epoch> (menos no --dry-run)."""
    # vazio → arquivo ausente = {} (todo relógio recomeça); falhou/ilegível/corrompido → {} também, mas só depois de guardar a cópia: relógio zerado é o lado inerte (nada fecha antes de 15 min)
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise Fail("não consegui ler %s: %s" % (path, e))
    try:
        obj = json.loads(raw.decode("utf-8"))
        sess = obj["sessoes"]
        if not isinstance(sess, dict):
            raise ValueError("sessoes")
    except (ValueError, KeyError, TypeError):
        dest, n = "%s.corrupt-%d" % (path, now), 1
        while os.path.exists(dest):
            n += 1
            dest = "%s.corrupt-%d-%d" % (path, now, n)
        if not dry:
            try:
                os.replace(path, dest)
            except OSError as e:
                raise Fail("não consegui gravar a cópia de %s: %s" % (path, e))
        print("hetzner-idle-session-reaper: AVISO: %s estava corrompido; %s %s" % (path, "a cópia ficou em" if not dry else "(--dry-run) a cópia iria para", dest), file=sys.stderr)
        return {}
    out = {}
    for k, v in sess.items():
        if isinstance(v, dict) and _int(v.get("desde")) is not None and _int(v.get("vivas_seguidas")) is not None:
            out[k] = {"desde": v["desde"], "vivas_seguidas": v["vivas_seguidas"]}  # entrada torta some: o relógio dela recomeça
    return out


# ---- leituras ----------------------------------------------------------------------------------------------------------------------------------------
def _ours(c, template):
    return isinstance(template, str) and any(template == t or template.endswith("/" + t) or template.endswith("." + t) for t in c.templates)


def read_sessions(c):
    """(linhas, ilegiveis, None) ou (None, 0, motivo). linhas = as sessões dos nossos templates que não estão fechadas."""
    # vazio → {"sessions": []} = nenhuma sessão nossa, nada a fazer (leu); falhou/ilegível/envelope de erro → (None, 0, motivo): ninguém é fechado e o estado não anda
    rc, out, _err, why = run_cmd([c.gc_bin, "--city", c.city, "session", "list", "--json"], c.gc_timeout_s)
    motivo = _failed(rc, why, "gc")
    if motivo:
        return None, 0, motivo
    try:
        d = json.loads(out)
    except ValueError:
        return None, 0, "json-ilegivel" if out.strip() else "saida-vazia"
    if isinstance(d, dict) and "ok" in d and d["ok"] is not True:  # envelope de erro: a lista que vier junto não vale
        return None, 0, "ok-falso"
    lst = d.get("sessions") if isinstance(d, dict) else None
    if not isinstance(lst, list):
        return None, 0, "sem-lista-sessions"
    rows, bad = [], 0
    for s in lst:
        if not isinstance(s, dict):
            bad += 1
        elif _ours(c, s.get("template")) and s.get("closed") is not True:
            rows.append(s)
    return rows, bad, None


def read_holders(c):
    """(assignees, None) ou (None, motivo). assignees = quem tem bead aberta ou in_progress (inclui as de infra: wisp/molecule/marker nascem efêmeras)."""
    # vazio → lista [] = ninguém segura bead (leu); saída vazia, falhou, travou ou forma estranha → (None, motivo): o chamador não fecha ninguém ("sem bead" nunca nasce de erro)
    rc, out, err, why = run_cmd([c.bd_bin, "-C", c.city, "list", "--include-infra", "--status", "open,in_progress", "--json", "--limit", "0"], c.bd_timeout_s)
    motivo = _failed(rc, why, "bd")
    if motivo:
        return None, motivo + (" " + _oneline(err, 80) if err.strip() else "")
    try:
        lst = json.loads(out)
    except ValueError:
        return None, "json-ilegivel" if out.strip() else "saida-vazia"
    if not isinstance(lst, list) or not all(isinstance(b, dict) and (b.get("assignee") is None or isinstance(b["assignee"], str)) for b in lst):
        return None, "forma-desconhecida"
    return {b["assignee"] for b in lst if b.get("assignee")}, None


def _str(s, key):
    return s[key] if isinstance(s.get(key), str) and s[key] else None


def describe(s):
    """(id ou None, nome, nomes pelos quais uma bead aponta para a sessão). id ausente ou '-' é linha torta: nunca vai para o `session close`."""
    sid = _str(s, "id")
    if sid == "-":
        sid = None
    owners = {v for v in (sid, _str(s, "session_name"), _str(s, "name"), _str(s, "alias")) if v}
    return sid, _str(s, "name") or _str(s, "session_name") or _str(s, "alias") or "?", owners


# ---- a rodada ----------------------------------------------------------------------------------------------------------------------------------------
def run(args, env):
    c = load_config(env)
    now, dry = c.now, args.dry_run
    off = os.path.join(c.gc_dir, "hetzner-idle-reaper.off")
    if os.path.exists(off):
        print("hetzner-idle-session-reaper: desligado (%s existe); não leio nada e não fecho nada" % off)
        return 0
    if not dry and take_lock(c.gc_dir) is None:
        print("hetzner-idle-session-reaper: outra instância ainda está rodando; saio sem medir (o lock é do kernel e some sozinho)", file=sys.stderr)
        return 0
    state_path = os.path.join(c.gc_dir, "hetzner-idle-reaper.state.json")
    old = load_state(state_path, now, dry)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))

    rows, ilegiveis, motivo = read_sessions(c)
    held = None
    if rows is not None and rows:  # nenhuma sessão nossa: o bd nem é chamado (e o Dolt fora do ar não atrapalha)
        held, motivo = read_holders(c)
    elif rows is not None:
        held = set()
    if motivo:
        print("%s não decidi nada: %s (ninguém foi fechado, o estado não andou)" % (ts, motivo))
        return 0

    new, closed, failed, events = {}, [], [], []
    com_bead = 0
    for s in rows:
        sid, nome, owners = describe(s)
        if held & owners:
            com_bead += 1  # segura bead: o relógio some
            continue
        if sid is None or s.get("closed") is not False:
            continue  # linha sem id de verdade, ou `closed` ausente (não sei se está aberta): nunca é fechada
        prev = old.get(sid)
        desde = prev["desde"] if prev and prev["desde"] <= now else now  # relógio que recuou: recomeça
        live = isinstance(s.get("state"), str) and s["state"] in LIVE
        runs = (prev["vivas_seguidas"] + 1 if prev else 1) if live else 0
        entry = {"desde": desde, "vivas_seguidas": runs}
        ocioso_s = now - desde
        # attached só vale como "ninguém anexado" se for False ou ausente; qualquer outro valor (true, "sim", 1) segura a sessão
        due = live and ocioso_s > c.grace_s and runs >= c.min_live_runs and s.get("attached") in (None, False)
        if not due:
            new[sid] = entry
            continue
        if dry:
            closed.append({"id": sid, "nome": nome, "ocioso_s": ocioso_s})
            continue
        # vazio → a releitura diz sem bead: fecha; falhou/ilegível ou apareceu bead → não fecha e o relógio fica (a próxima rodada decide de novo)
        held2, why2 = read_holders(c)
        if held2 is None or held2 & owners:
            new[sid] = entry
            events.append({"evento": "nao-fechada", "id": sid, "nome": nome, "motivo": why2 if held2 is None else "bead-apareceu"})
            continue
        rc, _o, err, why = run_cmd([c.gc_bin, "--city", c.city, "session", "close", sid], c.gc_timeout_s)
        cmotivo = _failed(rc, why, "gc-close")
        if cmotivo:
            new[sid] = entry
            failed.append({"id": sid, "nome": nome, "motivo": cmotivo})
            events.append({"evento": "fechar-falhou", "id": sid, "nome": nome, "motivo": cmotivo, "detalhe": _oneline(err)})
        else:
            closed.append({"id": sid, "nome": nome, "ocioso_s": ocioso_s})
            events.append({"evento": "fechada", "id": sid, "nome": nome, "ocioso_s": ocioso_s, "vivas_seguidas": runs})
    resumo = "%s sessoes=%d com_bead=%d %s=%d falhas=%d ilegiveis=%d" % (ts, len(rows), com_bead, "fecharia" if dry else "fechadas", len(closed), len(failed), ilegiveis)
    if dry:
        print(resumo + "".join("\n  fecharia: %s (%s) sem bead há %d s" % (x["id"], x["nome"], x["ocioso_s"]) for x in closed))
        return 0
    write_atomic(state_path, json.dumps({"versao": 1, "sessoes": new, "atualizado_em": now}, ensure_ascii=False, sort_keys=True, indent=1))
    for ev in events:
        ev.update(ts=ts, epoch=now)
        append_line(os.path.join(c.gc_dir, "hetzner-idle-reaper.jsonl"), json.dumps(ev, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    if closed or failed:
        append_line(os.path.join(c.gc_dir, "hetzner-occupancy.jsonl"), json.dumps(
            {"ts": ts, "epoch": now, "tipo": "reaper", "fechadas": closed, "falhas": failed}, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    print(resumo)
    return 0


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="fecha a sessão remota do Hetzner sem bead há mais de 15 min (ga-mu9k7m)")
    ap.add_argument("--dry-run", action="store_true", help="lê tudo e mostra o que fecharia; não fecha nem grava nada")
    args = ap.parse_args(argv)
    try:
        return run(args, os.environ)
    except Fail as e:
        print("hetzner-idle-session-reaper: %s" % e, file=sys.stderr)
        return e.rc
    except Exception:  # inclui configuração inválida: o traceback fica à vista no log do launchd
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
