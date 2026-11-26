#!/usr/bin/env python3
"""nightly-reboot-crew-proof.py (ga-esorlre.15, layer 3 of ga-esorlre.12): at 00:10, after the nightly reboot, PROVES that every named crew that had a bead in_progress at the boot has done something since: a commit in
its clone, or a comment of its own on one of its in_progress beads. No proof = a night of work lost = a push that vibrates the Athos's phone. Layers 1-2 prevent it; this one MEASURES it, and depends on nothing the crews
depend on (no engine, pane or session): launchd, the files of the city, bd, git, notify. Install and log lines: docs/runbooks/nightly-reboot-crew-proof.md; knobs: the NRCP_* names read in Cfg.

WINDOW  boot = kern.boottime, the night's only if >= the last 23:00 local (older = no reboot tonight, nothing judged). Deadline = max(00:10 local, boot + 20 min); the run waits for it (--dry-run does not).
ASKED   named crews (Layer-1 rule: agents/<n>/agent.toml with work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1), not suspended (agent.toml, or their rig in city.toml), with a bead in_progress AT the
  boot: assignee = the crew or <crew>-gawisp<tail>, in the rig store or the HQ store, started before the boot (a start that cannot be read counts as before). No such bead = not asked.
PROOF   between boot and deadline: a `commit` entry in the reflog of the clone (a pull is not one), or a comment AUTHORED by the crew (<crew> or <crew>-...: automation, orders, Mayor and Pilot do not count) on
  one of those beads.
STATES  every read is retried NRCP_TRIES times; one that still fails is NAO-SEI: never "none" and never ok. OK as soon as any readable source proves; FALTA only if every source was read and none proves.
  FALTA and NAO-SEI both push, twice if needed: priority 4 + NOTIFY_FORCE_PUSH (the default route is the silent digest) + NOTIFY_STRICT_EXIT (only then does notify's exit code say whether the phone was reached:
  0 and 11 yes; 10 held-until-07:00, 12, 13, 14 and timeout no); the text carries the dates (notify drops a repeated text). Not delivered = ERROR + stderr "NÃO ENTREGUE". A good night sends only the routine
  digest line (and names the crews it did not cover), so "no alarm" can be told from "no guard". A crash is the same alarm. --dry-run judges as of now and sends and writes nothing.
EXIT    0 nothing to prove / all proven / off (touch .gc/nightly-reboot-crew-proof.off) · 1 an alarm was raised · 2 usage."""
import calendar
import datetime
import json
import os
import re
import subprocess
import sys
import time

CITY_DEFAULT = "/Users/athos/gt/.gascity-gastown-hq"
USAGE = "usage: nightly-reboot-crew-proof.py [--dry-run]"
TITLE_MISSING, TITLE_UNKNOWN, TITLE_OK = "Reboot noturno: crew SEM retomar", "Reboot noturno: retomada das crews NÃO CONFERIDA", "Reboot noturno: crews retomaram"
MAX_BODY = 800  # a phone notification: the rest is in the log
NOTIFY_DELIVERED = (0, 11)  # `notify` with NOTIFY_STRICT_EXIT=1: 0 pushed, 11 the same text already went out; 10 held until 07:00 (too late for 00:10), 12 digest/cap, 13, 14, a timeout, anything else: not delivered
COMMIT_RE = re.compile(r"^commit( \([a-z-]+\))?:")  # reflog subjects of a local commit: `commit:`, `commit (amend):`, `commit (merge):`
REFLOG_RE = re.compile(r"^\S+@\{(\d+)\}\t(.*)$")
TS_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)$")


def num(v, default):
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return default
    return n if n > 0 else default


def hhmm(v, default):
    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", (v or "").strip())
    return (int(m.group(1)), int(m.group(2))) if m else default


class Cfg:
    def __init__(self, env):
        g = env.get
        self.city = g("NRCP_CITY") or g("GC_CITY_PATH") or CITY_DEFAULT
        gc_dir = os.path.join(self.city, ".gc")
        self.agents, self.city_toml, self.off_path = os.path.join(self.city, "agents"), os.path.join(self.city, "city.toml"), os.path.join(gc_dir, "nightly-reboot-crew-proof.off")
        self.log_path = g("NRCP_LOG") or os.path.join(gc_dir, "logs", "nightly-reboot.log")
        self.sysctl, self.bd, self.git = g("NRCP_SYSCTL") or g("SYSCTL_BIN") or "/usr/sbin/sysctl", g("NRCP_BD") or g("BD_BIN") or "bd", g("NRCP_GIT") or "git"
        self.notify = g("NRCP_NOTIFY") or g("NOTIFY_BIN") or "notify"
        self.window_from, self.deadline_at = hhmm(g("NRCP_WINDOW_FROM_HHMM"), (23, 0)), hhmm(g("NRCP_DEADLINE_HHMM"), (0, 10))
        self.grace_s, self.tries, self.retry_s, self.call_t, self.notify_pause = num(g("NRCP_MIN_GRACE_S"), 1200), num(g("NRCP_TRIES"), 3), num(g("NRCP_RETRY_S"), 20), num(g("NRCP_CALL_TIMEOUT_S"), 90), num(g("NRCP_NOTIFY_RETRY_S"), 15)


class RealIO:
    now, sleep = staticmethod(time.time), staticmethod(time.sleep)

    def run(self, argv, timeout, env=None):
        """(rc, stdout, stderr); rc None = could not start or timed out: never an empty answer."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout, env=dict(os.environ, **env) if env else None)
        except (OSError, subprocess.SubprocessError):
            return None, "", ""
        return p.returncode, p.stdout, p.stderr


class Log:
    def __init__(self, path, dry):
        self.path, self.dry = path, dry

    def __call__(self, msg):
        line = "[%s] crew-proof: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        if self.dry:
            return print(line)
        # falhou (diretório ausente, disco cheio) → aviso no stderr e segue: o log não é condição para conferir nem para alertar
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as ex:
            sys.stderr.write("WARN: cannot append to %s: %s\n" % (self.path, ex))


def hm(t): return time.strftime("%H:%M", time.localtime(t))
def fdm(t): return time.strftime("%d/%m %H:%M", time.localtime(t))


def last_local(now, hh, mm):
    """the latest instant <= now whose LOCAL clock reads hh:mm"""
    d = datetime.datetime.fromtimestamp(now).replace(hour=hh, minute=mm, second=0, microsecond=0)
    return (d - datetime.timedelta(days=1) if d.timestamp() > now else d).timestamp()


def first_local_after(t, hh, mm):
    """the earliest instant > t whose LOCAL clock reads hh:mm"""
    d = datetime.datetime.fromtimestamp(t).replace(hour=hh, minute=mm, second=0, microsecond=0)
    return (d + datetime.timedelta(days=1) if d.timestamp() <= t else d).timestamp()


def parse_ts(v):
    """RFC3339 with an explicit zone (what bd prints: ...Z) -> epoch; None = not readable. A time without a zone is not guessed: it would shift the verdict by hours."""
    m = TS_RE.match(v.strip()) if isinstance(v, str) else None
    if not m:
        return None
    try:  # datetime validates the date (calendar.timegm turns 2026-11-31 into 2026-12-01)
        t = calendar.timegm(datetime.datetime(*(int(m.group(i)) for i in range(1, 7))).timetuple())
    except (ValueError, OverflowError):
        return None
    z = m.group(7)
    return t if z == "Z" else t - (1 if z[0] == "+" else -1) * (int(z[1:3]) * 3600 + int(z[-2:]) * 60)


def ask(io, cfg, argv, parse=None, env=None):
    """Runs argv up to cfg.tries times -> (True, value) or (False, why). An answer that exits 0 but that `parse` rejects (ValueError) counts as failed and is retried: a half-written answer is never an empty one."""
    why = "?"
    for i in range(cfg.tries):
        rc, out, _err = io.run(argv, cfg.call_t, env)
        if rc == 0:
            try:
                return True, (parse(out) if parse else out)
            except ValueError as ex:
                why = "resposta ilegível (%s)" % ex
        else:
            why = "sem resposta em %ds (estouro ou não iniciou)" % cfg.call_t if rc is None else "rc=%s" % rc
        if i + 1 < cfg.tries:
            io.sleep(cfg.retry_s)
    return False, why


def parse_boot(out):
    m = re.search(r"\bsec\s*=\s*(\d+)\b", out)  # `{ sec = 1789579812, usec = 958892 }`: the token `sec`, never the one inside `usec`
    if not m:
        raise ValueError("sem o campo sec")
    return int(m.group(1))


def parse_list(out, objects=False):
    d = json.loads(out)
    if not isinstance(d, list) or (objects and not all(isinstance(r, dict) for r in d)):  # a row we cannot read could be the very bead we look for
        raise ValueError("não é uma lista JSON" + (" de objetos" if objects else ""))
    return d


def parse_reflog(out):
    """-> (entries [(epoch, subject)], number of lines that are not in the `ref@{epoch}<TAB>subject` form)"""
    ms = [REFLOG_RE.match(line) for line in out.splitlines() if line.strip()]
    return [(int(m.group(1)), m.group(2)) for m in ms if m], sum(1 for m in ms if not m)


def load_crews(cfg):
    """-> ({name: {"wd", "rig", "rig_path"}} of the named crews not suspended in their agent.toml, ""); (None, why) = unreadable."""
    # vazio (agents/ sem nenhuma crew) → {}: nada a provar; falhou/ilegível (pasta ou algum agent.toml sem leitura) → None: a rodada inteira vira NÃO SEI; pasta sem agent.toml → não é crew
    try:
        names = sorted(os.listdir(cfg.agents))
    except OSError as ex:
        return None, "agents/ ilegível (%s)" % ex.__class__.__name__
    out = {}
    for n in names:
        try:
            with open(os.path.join(cfg.agents, n, "agent.toml"), encoding="utf-8") as fh:
                txt = fh.read()
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as ex:
            return None, "agents/%s/agent.toml ilegível (%s)" % (n, ex.__class__.__name__)
        wd = re.search(r"""^work_dir\s*=\s*(?:"([^"]*)"|'([^']*)')""", txt, re.M)  # either quote is valid TOML, and so is a trailing slash: a crew must not vanish from the proof over them
        mx = re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        path = (wd.group(1) if wd.group(1) is not None else wd.group(2)).rstrip("/") if wd else ""
        slug = re.search(r"^(.*)/crew/([^/]+)$", path)
        if slug and slug.group(2) != "worker" and not (mx and int(mx.group(1)) > 1) and not re.search(r"^[ \t]*suspended[ \t]*=[ \t]*true\b", txt, re.M):
            out[n] = {"wd": path, "rig_path": slug.group(1), "rig": os.path.basename(slug.group(1))}
    return out, ""


def load_rigs(cfg):
    """-> ({rig name: suspended}, ""); (None, why) = unreadable. Only the keys between `[[rigs]]` and the next table header are the rig's own (`suspended` under [rigs.imports...] is another table's)."""
    # vazio (nenhum [[rigs]]) → {}: nenhum rig suspenso; falhou/ilegível (city.toml sem leitura) → None: a rodada inteira vira NÃO SEI
    try:
        with open(cfg.city_toml, encoding="utf-8") as fh:
            txt = fh.read()
    except (OSError, ValueError) as ex:
        return None, "city.toml ilegível (%s)" % ex.__class__.__name__
    blocks = re.findall(r"(?ms)^\[\[rigs\]\][ \t]*(?:#[^\n]*)?\n(.*?)(?=^\[|\Z)", txt)
    return {m.group(1): bool(re.search(r"(?m)^suspended\s*=\s*true\b", b)) for b in blocks for m in [re.search(r'(?m)^name\s*=\s*"([^"]*)"', b)] if m}, ""


def mine(crew, assignee):
    """the crew by its name or by its session name <crew>-gawisp<tail>: `peter-wa` and `peter-wa-gawisp1` yes, `peter-wax` and `peter-ma` no"""
    return isinstance(assignee, str) and (assignee == crew or assignee.startswith(crew + "-"))


def split_beads(rows, crew, boot):
    """-> (ids of the crew's beads in progress AT the boot, number of those rows with no readable id: their comments cannot be asked for, so NAO-SEI, never "no bead")"""
    ids, bad = [], 0
    for r in rows:
        started = parse_ts(r.get("started_at"))
        # início ausente ou ilegível → assume que estava em andamento no boot (conferir a mais, nunca a menos); começou no boot ou depois → não estava em andamento no boot: não é o que se cobra
        if not mine(crew, r.get("assignee")) or r.get("status") not in (None, "in_progress") or (started is not None and started >= boot):
            continue
        if isinstance(r.get("id"), str) and r["id"]:
            ids.append(r["id"])
        else:
            bad += 1
    return ids, bad


def commit_evidence(io, cfg, wd, boot, deadline):
    """-> (found|none|unknown, epoch of the first proof, why). A `commit` entry in the reflog of the clone = the crew made it itself (a pull is `pull`, `git log` would credit it with everybody's merges)."""
    # vazio (reflog sem entrada `commit` na janela, ou sem entradas) → none; falhou/ilegível (git rc≠0/estouro, ou linha fora do formato e nenhum commit achado) → unknown
    ok, val = ask(io, cfg, [cfg.git, "-C", wd, "reflog", "show", "--all", "--date=unix", "--format=%gd%x09%gs"], parse=parse_reflog, env={"GIT_OPTIONAL_LOCKS": "0"})
    if not ok:
        return "unknown", None, "git reflog em %s: %s" % (wd, val)
    entries, junk = val
    found = [t for t, subj in entries if COMMIT_RE.match(subj) and boot <= t <= deadline]
    return ("found", min(found), "") if found else ("unknown", None, "git reflog: %d linha(s) fora do formato" % junk) if junk else ("none", None, "")


def comment_evidence(io, cfg, store, bid, crew, boot, deadline):
    """-> (found|none|unknown, epoch of the first proof, why). A comment counts only if its AUTHOR is the crew."""
    # vazio ([] ou só comentários de outros/fora da janela) → none; falhou/ilegível (bd rc≠0/estouro, não é lista, comentário sem horário legível ou, na janela, sem autor) → unknown
    ok, val = ask(io, cfg, [cfg.bd, "-C", store, "comments", bid, "--json"], parse=parse_list)
    if not ok:
        return "unknown", None, "bd comments %s: %s" % (bid, val)
    found, bad = [], []
    for c in val:
        t = parse_ts(c.get("created_at")) if isinstance(c, dict) else None
        if t is None:
            bad.append("comentário com formato ou horário ilegível")
        elif boot <= t <= deadline:  # before the boot or after the deadline it is irrelevant, whoever wrote it
            a = c.get("author")
            if not isinstance(a, str) or not a:
                bad.append("comentário da janela sem autor")
            elif mine(crew, a):
                found.append(t)
    return ("found", min(found), "") if found else ("unknown", None, "bd comments %s: %s" % (bid, bad[0])) if bad else ("none", None, "")


def judge(io, cfg, crew, info, beads, fails, boot, deadline):
    """-> dict(state OK|FALTA|NAO-SEI, ...). OK as soon as ANY readable source proves; FALTA only if every source was read and none does; NAO-SEI otherwise."""
    r, why = {"crew": crew, "beads": [b for _s, b in beads]}, []
    state, when, w = commit_evidence(io, cfg, info["wd"], boot, deadline)
    if state == "found":
        return dict(r, state="OK", kind="commit", when=when)
    if state == "unknown":
        why.append(w)
    for store, bid in beads:
        state, when, w = comment_evidence(io, cfg, store, bid, crew, boot, deadline)
        if state == "found":
            return dict(r, state="OK", kind="comentário em %s" % bid, when=when)
        if state == "unknown":
            why.append(w)
    return dict(r, state="NAO-SEI" if why or fails else "FALTA", why=why + fails)


def clip(items, budget):
    out, used = [], 0
    for i, it in enumerate(items):
        if used + len(it) + 1 > budget:
            return out + ["… +%d" % (len(items) - i)]
        out.append(it)
        used += len(it) + 1
    return out


def push(io, cfg, log, title, body, force):
    """notify -> delivered? The alarm (force) is tried twice and carries FORCE_PUSH + STRICT_EXIT (see NOTIFY_DELIVERED); the routine digest line is plain notify, MEANT for the digest."""
    argv, kind = [cfg.notify, "-t", title, "-p", "4" if force else "3", body], "push p4" if force else "digest p3"
    for i in range(2 if force else 1):
        # vazio → n/a (a chamada só devolve um código de saída); falhou/ilegível (rc fora do que vale, estouro, não iniciou) → "não entregue": tenta de novo e, no alarme, acaba em ERROR + stderr
        rc, _o, _e = io.run(argv, 60, {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"} if force else None)
        if (rc in NOTIFY_DELIVERED) if force else (rc == 0):
            return log("notify %s: enviado (rc=%s)" % (kind, rc)) or True
        log("WARN: notify %s falhou (rc=%s), tentativa %d" % (kind, rc, i + 1))
        if force and i == 0:
            io.sleep(cfg.notify_pause)
    return False


def alarm(io, cfg, log, dry, title, body):
    if dry:
        return print("DRY-RUN: enviaria push p4 (force): %s\n%s" % (title, body))
    if not push(io, cfg, log, title, body, True):
        msg = "ALERTA NÃO ENTREGUE: o push falhou 2x — %s: %s" % (title, body.replace("\n", " | "))
        log("ERROR: " + msg)
        sys.stderr.write(msg + "\n")


def alarm_unknown(io, cfg, log, dry, why):
    log("NAO-SEI: " + why)
    alarm(io, cfg, log, dry, TITLE_UNKNOWN, "Em %s não consegui conferir se as crews retomaram: %s.\nConfira à mão: nightly-reboot-crew-proof.py --dry-run\nLog: %s" % (fdm(io.now()), why, cfg.log_path))
    return 1


def run(io, cfg, log, dry):
    now = io.now()
    # vazio (sysctl sem o campo sec) → NÃO SEI, nunca "sem reboot"; falhou/ilegível (rc≠0, estouro, resposta que não é kern.boottime) → o mesmo: alerta
    ok, boot = ask(io, cfg, [cfg.sysctl, "-n", "kern.boottime"], parse=parse_boot)
    if not ok:
        return alarm_unknown(io, cfg, log, dry, "não consegui ler o horário do boot (kern.boottime): %s" % boot)
    start = last_local(now, *cfg.window_from)
    if boot < start:
        log("o boot de %s é anterior à janela noturna (desde %s): sem reboot esta noite, nada a provar" % (fdm(boot), fdm(start)))
        return 0
    if boot > now:
        return alarm_unknown(io, cfg, log, dry, "o boot (%s) é depois de agora (%s): relógio ou kern.boottime fora do normal" % (fdm(boot), fdm(now)))
    deadline = max(first_local_after(start, *cfg.deadline_at), boot + cfg.grace_s)
    if dry:
        deadline = min(deadline, now)
    elif now < deadline:
        log("boot de %s, prazo %s: espero %ds" % (fdm(boot), fdm(deadline), deadline - now))
        io.sleep(deadline - now)
    crews, why = load_crews(cfg)
    rigs, why2 = load_rigs(cfg) if crews is not None else ({}, "")
    if crews is None or rigs is None:
        return alarm_unknown(io, cfg, log, dry, "não consegui ler " + (why if crews is None else why2))
    asked = {n: i for n, i in crews.items() if not rigs.get(i["rig"], False)}
    log("boot %s, prazo %s: %d crew(s) nomeada(s) ativa(s) (%d em rig suspenso, fora)" % (fdm(boot), fdm(deadline), len(asked), len(crews) - len(asked)))
    # vazio ([]) → (True, []): nenhuma bead em andamento ali; falhou/ilegível (rc≠0, estouro, JSON que não é lista de objetos) → (False, why): NÃO SEI daquele store
    stores = {st: ask(io, cfg, [cfg.bd, "-C", st, "list", "--status", "in_progress", "--json", "--limit", "0"], parse=lambda o: parse_list(o, True))
              for st in sorted({i["rig_path"] for i in asked.values()} | {cfg.city})} if asked else {}
    results, idle = [], []
    for crew in sorted(asked):
        info, beads, fails = asked[crew], [], []
        for st in (info["rig_path"], cfg.city):
            ok, val = stores[st]
            name = os.path.basename(st.rstrip("/"))
            if not ok:
                fails.append("não consegui listar as beads em andamento de %s (bd list: %s)" % (name, val))
                continue
            ids, bad = split_beads(val, crew, boot)
            beads += [(st, b) for b in ids]
            if bad:
                fails.append("%d bead(s) em andamento de %s em %s sem id legível" % (bad, crew, name))
        if not beads and not fails:
            idle.append(crew)
            continue
        r = judge(io, cfg, crew, info, beads, fails, boot, deadline)
        results.append(r)
        log("%s OK: %s às %s (%s)" % (crew, r["kind"], hm(r["when"]), ",".join(r["beads"])) if r["state"] == "OK" else "%s %s: %s%s" % (crew, r["state"], ",".join(r["beads"]) or "sem bead", " — " + "; ".join(r["why"]) if r["why"] else ""))
    missing, unknown = [r for r in results if r["state"] == "FALTA"], [r for r in results if r["state"] == "NAO-SEI"]
    uncovered = " Sem bead em andamento no boot (não cobradas): %s." % ", ".join(idle) if idle else ""
    if not missing and not unknown:
        body = ("%d crew(s) com bead em andamento no boot (%s) retomaram até %s: %s." % (len(results), hm(boot), hm(deadline), ", ".join("%s (%s %s)" % (r["crew"], r["kind"].split(" ")[0], hm(r["when"])) for r in results))
                if results else "nenhuma crew tinha bead em andamento no boot (%s): nada a provar." % hm(boot)) + uncovered
        log("RESULT: " + body)
        if dry:
            print("DRY-RUN: enviaria digest p3: %s\n%s" % (TITLE_OK, body))
        elif not push(io, cfg, log, TITLE_OK, body, False):
            log("ERROR: o aviso de rotina (digest) não saiu; sem alarme, só falta o recibo")
        return 0
    lines = (["Sem commit nem comentário seu desde o boot:"] + ["• %s: %s" % (r["crew"], ",".join(r["beads"])) for r in missing] if missing else []) \
        + (["Não consegui conferir:"] + ["• %s: não consegui ler — %s" % (r["crew"], "; ".join(r["why"])) for r in unknown] if unknown else [])
    head, foot = "Boot %s, prazo %s." % (fdm(boot), fdm(deadline)), "Log: %s" % cfg.log_path  # with the dates: the same crew silent two nights in a row is two alarms, not one repeated text that notify drops
    log("RESULT: %d FALTA, %d NAO-SEI, %d OK;%s" % (len(missing), len(unknown), len(results) - len(missing) - len(unknown), uncovered or " todas as crews ativas tinham bead"))
    alarm(io, cfg, log, dry, TITLE_MISSING if missing else TITLE_UNKNOWN, "\n".join([head] + clip(lines, MAX_BODY - len(head) - len(foot) - 8) + [foot]))
    return 1


def main(argv=None, env=None, io=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv not in ([], ["--dry-run"]):
        sys.stderr.write(USAGE + "\n")
        return 2
    cfg, dry, io = Cfg(os.environ if env is None else env), argv == ["--dry-run"], RealIO() if io is None else io
    log = Log(cfg.log_path, dry)
    if os.path.exists(cfg.off_path):
        log("desligado (%s existe): nada conferido" % cfg.off_path)
        return 0
    try:
        return run(io, cfg, log, dry)
    except Exception as ex:  # noqa: BLE001 - a crash must not be a traceback in a launchd .err file nobody reads: it is the same alarm as "could not look" (a dry run just raises)
        if dry:
            raise
        return alarm_unknown(io, cfg, log, False, "a conferência quebrou (%s: %s)" % (ex.__class__.__name__, str(ex)[:200]))


if __name__ == "__main__":
    sys.exit(main())
