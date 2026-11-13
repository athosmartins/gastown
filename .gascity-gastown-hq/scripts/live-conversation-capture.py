#!/usr/bin/env python3
"""live-conversation-capture.py (ga-esorlre.2): keeps, in the SESSION BEAD of the Mayor and of every named crew, the id of the conversation that is ALIVE in its pane.

WHY  After a reboot each crew must come back in the conversation the Athos was using. The bead's session_key is NOT it (he switches with /resume inside the crew); the live id exists only
  in ~/.claude/sessions/<pid>.json, which a reboot wipes of meaning. Readers: ga-esorlre.1 (reaper), .3 (boot), .5 (proof).
CONTRACT  metadata of the session bead (the `id` of `gc session list --json`); both keys go in ONE `bd update`, read back before a pass counts it as written:
  session.live_conversation_id = sessionId of the claude alive in the pane (= its transcript name <id>.jsonl; written only if that transcript exists)
  session.live_conversation_at = epoch s of the last WRITE: a change is written on the next pass, an unchanged id is re-confirmed every LCC_REFRESH_S (30 min, to spare Dolt) and ALWAYS by --final
HOW  Targets: active gastown.mayor + named crews (Layer-1 rule of crew-idle-check.sh; pool workers out). Per target: tmux list-panes -> pane pid -> process tree (ps) -> the
  ~/.claude/sessions/<pid>.json of a process in it; a file older than its process is a leftover of an earlier holder of the pid (reboots leave them) and is ignored.
THREE STATES  live (one conversation, with a transcript: written) / absent (no claude in the pane, no transcript yet, no tmux session) / unknown (two conversations in one pane, unreadable
  file, tmux/ps/gc failed, budget spent). Absent and unknown never write and never erase: the last good value stays and the reason is logged.
RUN  launchd every 120 s (instance lock, budget LCC_BUDGET_S 90) + `--final` (lock wait, budget 20 s) from the D4 and nightly reboot scripts; `--dry-run` writes nothing. stdout = ONE summary line;
  events go to .gc/logs/live-conversation-capture.log; last written (bead -> id, at) in .gc/live-conversation-capture.state.json (unreadable = one more harmless write).
KNOBS  LCC_ENABLED=0 or .gc/live-conversation-capture.off · LCC_HOME · LCC_CLAUDE_DIR · LCC_GC · LCC_BD · LCC_TMUX · LCC_TMUX_SOCKET · LCC_REFRESH_S · LCC_BUDGET_S · LCC_FINAL_BUDGET_S ·
  LCC_LOCK_WAIT_S · LCC_GC_TIMEOUT_S/LCC_BD_TIMEOUT_S/LCC_SYS_TIMEOUT_S.  EXIT 0 evaluated · 2 usage · 3 could not evaluate · 4 another instance runs.
"""
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

CITY_DEFAULT = "/Users/athos/gt/.gascity-gastown-hq"
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
K_ID, K_AT = "session.live_conversation_id", "session.live_conversation_at"
MAYORS = ("gastown.mayor", "mayor")
START_SLACK_S = 3  # ps etime has 1 s resolution: a registry file may look this much older than its process and still be its own
MAX_DEPTH = 8


def num(v, default):
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return default
    return n if n > 0 else default


class Cfg:
    def __init__(self, env):
        g = env.get
        self.city = g("GC_CITY_PATH") or CITY_DEFAULT
        self.home = g("LCC_HOME") or os.path.expanduser("~")
        self.claude = g("LCC_CLAUDE_DIR") or os.path.join(self.home, ".claude")
        self.gc = [g("LCC_GC") or g("GC_BIN") or "gc", "--city", self.city]
        self.bd = [g("LCC_BD") or g("BD_BIN") or "bd", "-C", self.city]
        self.tmux = [g("LCC_TMUX") or "tmux", "-L", g("LCC_TMUX_SOCKET") or "gascity"]
        self.refresh_s, self.budget_s, self.final_budget_s = num(g("LCC_REFRESH_S"), 1800), num(g("LCC_BUDGET_S"), 90), num(g("LCC_FINAL_BUDGET_S"), 20)
        self.lock_wait_s, self.gc_t, self.bd_t, self.sys_t = num(g("LCC_LOCK_WAIT_S"), 10), num(g("LCC_GC_TIMEOUT_S"), 45), num(g("LCC_BD_TIMEOUT_S"), 30), num(g("LCC_SYS_TIMEOUT_S"), 10)
        gc_dir = os.path.join(self.city, ".gc")
        self.agents, self.state = os.path.join(self.city, "agents"), os.path.join(gc_dir, "live-conversation-capture.state.json")
        self.lock, self.log = os.path.join(gc_dir, "live-conversation-capture.lock"), os.path.join(gc_dir, "logs", "live-conversation-capture.log")
        self.enabled = g("LCC_ENABLED", "1") != "0" and not os.path.exists(os.path.join(gc_dir, "live-conversation-capture.off"))


class RealIO:
    now, sleep = staticmethod(time.time), staticmethod(time.sleep)

    def run(self, argv, timeout):
        """(rc, stdout, stderr); rc None = could not start or timed out: never an empty answer."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout)
        except (OSError, subprocess.SubprocessError):
            return None, "", ""
        return p.returncode, p.stdout, p.stderr


class Log:
    def __init__(self, path, dry):
        self.path, self.dry = path, dry

    def __call__(self, msg):
        line = "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        if self.dry:
            print(line)
            return
        # falhou (diretório ausente, disco cheio) → aviso no stderr e segue: o log não é condição para capturar
        try:
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as ex:
            sys.stderr.write("WARN: cannot append to %s: %s\n" % (self.path, ex))


def crew_names(agents_dir):
    """Named crews (Layer-1 rule): agent dir names whose agent.toml has work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1. None = unreadable."""
    # vazio (nenhuma crew) → set(): só o Mayor é alvo; falhou/ilegível (diretório ou agent.toml sem leitura) → None: o passe sai 3 sem gravar; pasta sem agent.toml → não é crew
    try:
        names = sorted(os.listdir(agents_dir))
    except OSError:
        return None
    out = set()
    for n in names:
        try:
            with open(os.path.join(agents_dir, n, "agent.toml"), encoding="utf-8") as fh:
                txt = fh.read()
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            return None
        wd, mx = re.search(r'^work_dir\s*=\s*"([^"]*)"', txt, re.M), re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        slug = re.search(r"/crew/([^/]+)$", wd.group(1)) if wd else None
        if slug and slug.group(1) != "worker" and not (mx and int(mx.group(1)) > 1):
            out.add(n)
    return out


def load_roster(io, cfg, tmo):
    # vazio (sessions: []) → []: nenhum alvo; falhou/ilegível (rc≠0, estouro, JSON ruim, "sessions" ausente ou não-lista) → None: o passe sai 3 sem gravar
    rc, out, _ = io.run(cfg.gc + ["session", "list", "--json"], tmo)
    if rc != 0:
        return None
    try:
        s = json.loads(out).get("sessions")
    except (ValueError, AttributeError):
        return None
    return s if isinstance(s, list) else None


def pick_targets(roster, crews):
    out = []
    for s in roster:
        if not isinstance(s, dict) or s.get("state") != "active":
            continue
        tpl, tname, bead = s.get("template"), s.get("session_name") or s.get("name"), s.get("id")  # a malformed row is skipped, never an exception that blinds the whole pass
        if isinstance(tpl, str) and (tpl in MAYORS or tpl.rsplit("/", 1)[-1] in crews) and isinstance(tname, str) and tname and isinstance(bead, str) and bead:
            out.append({"bead": bead, "tname": tname})
    return sorted(out, key=lambda t: t["tname"])


def parse_etime(s):
    m = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", s)
    return None if not m else int(m.group(1) or 0) * 86400 + int(m.group(2) or 0) * 3600 + int(m.group(3)) * 60 + int(m.group(4))


def ps_table(io, tmo):
    """{pid: (ppid, start epoch)}; None = ps could not be read (a machine always has processes: an empty table is unreadable too)."""
    # vazio/ilegível (nenhuma linha que eu entenda) → None; falhou (rc≠0, estouro) → None: todo alvo vira unknown, nada é gravado
    rc, out, _ = io.run(["ps", "-axo", "pid=,ppid=,etime="], tmo)
    if rc != 0:
        return None
    t, tab = io.now(), {}  # the age is only true at THIS instant: the start is fixed now, later reads of the pass must not move it
    for ln in out.splitlines():
        f = ln.split()
        age = parse_etime(f[2]) if len(f) == 3 and f[0].isdigit() and f[1].isdigit() else None
        if age is not None:
            tab[int(f[0])] = (int(f[1]), t - age)
    return tab or None


def pane_pids(io, cfg, tname, tmo):
    """("ok", [pane pids]) / ("absent", why) / ("unknown", why)."""
    # vazio (rc 1 com "can't find session": o servidor tmux respondeu e a sessão não existe) → absent: sem pane não há claude vivo; falhou (estouro, tmux ausente, servidor fora/socket sem acesso
    # — também rc 1, mas com outra mensagem —, saída sem pid) → unknown: não consegui perguntar não é "não existe"
    rc, out, err = io.run(cfg.tmux + ["list-panes", "-s", "-t", "=%s:" % tname, "-F", "#{pane_pid}"], tmo)
    if rc is None:
        return "unknown", "tmux did not answer (timeout or not runnable)"
    if rc != 0:
        why = "tmux rc=%d: %s" % (rc, (err or "").strip()[:80])
        return ("absent" if "can't find session" in (err or "") else "unknown"), why
    pids = [int(x) for x in out.split() if x.isdigit()]
    return ("ok", pids) if pids else ("unknown", "tmux answered with no pane pid")


def descend(tab, roots):
    kids = {}
    for pid, (pp, _) in tab.items():
        kids.setdefault(pp, []).append(pid)
    seen, level = set(roots), list(roots)
    for _ in range(MAX_DEPTH):
        level = [k for p in level for k in kids.get(p, []) if k not in seen]
        seen.update(level)
    return sorted(seen)


def read_entry(claude, pid, start):
    """("ok", registry entry) / ("none", None) / ("bad", why) for ~/.claude/sessions/<pid>.json of the live process that started at `start`."""
    path = os.path.join(claude, "sessions", "%d.json" % pid)
    # vazio (sem arquivo) → none: o processo não é um claude; falhou/ilegível (sem permissão, JSON ruim, sem sessionId uuid) → bad: o alvo fica unknown, nada é gravado
    try:
        mt = os.stat(path).st_mtime
    except FileNotFoundError:
        return "none", None
    except OSError as ex:
        return "bad", "cannot stat %s: %s" % (os.path.basename(path), ex)
    if mt < start - START_SLACK_S:
        return "none", None  # older than the process that now owns this pid: a leftover of an earlier holder
    try:
        with open(path, encoding="utf-8") as fh:
            e = json.load(fh)
    except (OSError, ValueError) as ex:
        return "bad", "cannot read %s: %s" % (os.path.basename(path), ex)
    if not isinstance(e, dict) or not isinstance(e.get("sessionId"), str) or not UUID_RE.fullmatch(e["sessionId"]) or e.get("pid") not in (None, pid):
        return "bad", "%s has no valid sessionId/pid" % os.path.basename(path)
    return ("ok", e) if e.get("kind") in (None, "interactive") else ("none", None)


def has_transcript(claude, sid):
    # vazio (nenhum arquivo) → False: a conversa ainda não é retomável; diretório sem leitura também dá False (o glob engole o erro): nos dois nada é gravado
    return bool(glob.glob(os.path.join(glob.escape(claude), "projects", "*", sid + ".jsonl")))


def resolve(io, cfg, tgt, tab, tmo):
    """("live", sessionId) / ("absent", why) / ("unknown", why) for one target."""
    st, pids = pane_pids(io, cfg, tgt["tname"], tmo)
    if st != "ok":
        return st, pids
    found = {}
    for pid in descend(tab, pids):
        if pid not in tab:
            continue
        s, e = read_entry(cfg.claude, pid, tab[pid][1])
        if s == "bad":
            return "unknown", e
        if s == "ok":
            found[e["sessionId"]] = e
    if not found:
        return "absent", "no claude registry entry under the pane"
    if len(found) > 1:
        return "unknown", "%d live conversations in one pane (%s)" % (len(found), " ".join(sorted(found)))
    sid, e = next(iter(found.items()))
    tm = e.get("tmux")
    if isinstance(tm, str) and tm and tm.split(":", 1)[0] != tgt["tname"]:
        return "unknown", "registry says tmux session %s, the target is %s" % (tm.split(":", 1)[0], tgt["tname"])
    if not has_transcript(cfg.claude, sid):
        return "absent", "conversation %s has no transcript on disk yet" % sid
    return "live", sid


def load_state(path):
    # vazio (arquivo ausente) → {}: nada gravado ainda; falhou/ilegível (JSON ruim, formato errado) → {}: o pior caso é gravar de novo o mesmo valor (inerte para o bead)
    try:
        with open(path, encoding="utf-8") as fh:
            b = json.load(fh).get("beads")
    except (OSError, ValueError, AttributeError):
        return {}
    return {k: v for k, v in b.items() if isinstance(v, dict)} if isinstance(b, dict) else {}


def save_state(path, beads):
    tmp = "%s.tmp%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"v": 1, "beads": beads}, fh, sort_keys=True)
    os.replace(tmp, path)


def persist(io, cfg, bead, sid, at, tmo):
    """(ok, why): ONE bd update with both keys, then a read-back of the id; only a value read back counts as written.
    The update and the read-back share ONE allowance (`tmo`, already clamped to the pass budget): the read-back gets what the update left of it (floor 1 s), so a slow Dolt cannot stretch a pass by a second full bd timeout."""
    t0 = io.now()
    rc, _, err = io.run(cfg.bd + ["update", bead, "--set-metadata", "%s=%s" % (K_ID, sid), "--set-metadata", "%s=%d" % (K_AT, at)], tmo)
    if rc != 0:
        return False, "bd update rc=%s: %s" % (rc, (err or "").strip()[:100])
    # falhou/ilegível (rc≠0, estouro, JSON ruim, sem a chave) → não gravado: o estado não o registra e a próxima rodada escreve de novo
    rc, out, _ = io.run(cfg.bd + ["show", bead, "--json"], max(1, int(tmo - (io.now() - t0))))
    if rc != 0:
        return False, "read-back failed (bd show rc=%s)" % rc
    try:
        got = json.loads(out)[0]["metadata"].get(K_ID)
    except (ValueError, LookupError, AttributeError, TypeError):
        return False, "read-back unreadable"
    return (True, "") if got == sid else (False, "read-back says %r, wrote %s" % (got, sid))


def run_pass(cfg, io, final=False, dry=False):
    """-> (exit code, counts). 0 evaluated · 3 could not evaluate (crew list or roster unreadable: nothing written)."""
    log = Log(cfg.log, dry)
    end = io.now() + (cfg.final_budget_s if final else cfg.budget_s)

    def left(cap):  # each call gets what is left of the pass budget, never less than 1 s
        return max(1, min(cap, int(end - io.now())))
    counts = dict.fromkeys(("targets", "wrote", "same", "absent", "unknown", "failed"), 0)
    crews = crew_names(cfg.agents)
    roster = None if crews is None else load_roster(io, cfg, left(cfg.gc_t))
    if roster is None:
        log("ERROR: cannot evaluate, nothing written: %s" % ("crew list (agents/) unreadable" if crews is None else "gc session list unreadable"))
        return 3, counts
    targets = pick_targets(roster, crews)
    counts["targets"] = len(targets)
    tab = ps_table(io, left(cfg.sys_t)) if targets else {}
    state = load_state(cfg.state)
    before = json.dumps(state, sort_keys=True)
    for tgt in targets:
        bead, tname = tgt["bead"], tgt["tname"]
        ent = state.setdefault(bead, {})
        if io.now() >= end:
            st, val = "unknown", "time budget of the pass spent before this target"
        elif tab is None:
            st, val = "unknown", "ps could not be read"
        else:
            st, val = resolve(io, cfg, tgt, tab, left(cfg.sys_t))
        if st != "live":
            counts[st] += 1
            note = "%s: %s" % (st, val)
            if ent.get("note") != note:
                log("%s %s (%s): %s — the last good value is kept" % (st.upper(), bead, tname, val))
                ent["note"] = note
            continue
        at = ent.get("at") if isinstance(ent.get("at"), (int, float)) else 0
        if not (final or ent.get("cid") != val or io.now() - at >= cfg.refresh_s):
            counts["same"] += 1
            ent["note"] = ""
            continue
        if dry:
            counts["wrote"] += 1
            log("WOULD write %s (%s): %s -> %s" % (bead, tname, ent.get("cid") or "-", val))
            continue
        ok, why = persist(io, cfg, bead, val, int(io.now()), left(cfg.bd_t))
        if not ok:
            counts["failed"] += 1
            log("FAILED %s (%s): %s" % (bead, tname, why))
            continue
        counts["wrote"] += 1
        if ent.get("cid") != val:
            log("WROTE %s (%s): %s -> %s" % (bead, tname, ent.get("cid") or "-", val))
        ent.update(cid=val, at=int(io.now()), note="")
    roster_ids = {s.get("id") for s in roster if isinstance(s, dict)}
    for b in [b for b in state if b not in roster_ids]:
        del state[b]
    if not dry and json.dumps(state, sort_keys=True) != before:
        try:
            save_state(cfg.state, state)
        except OSError as ex:
            log("WARN: cannot save %s: %s — the next pass writes again (harmless)" % (cfg.state, ex))
    return 0, counts


def main(argv=None, env=None, io=None):
    argv = sys.argv[1:] if argv is None else argv
    if not set(argv) <= {"--final", "--dry-run"} or len(set(argv)) != len(argv):
        sys.stderr.write("usage: live-conversation-capture.py [--final] [--dry-run]\n")
        return 2
    final, dry = "--final" in argv, "--dry-run" in argv
    cfg, io = Cfg(os.environ if env is None else env), io or RealIO()
    tag = "live-conversation-capture%s:" % ("[final]" if final else "")
    if not cfg.enabled:
        print("%s desligado (LCC_ENABLED=0 ou .gc/live-conversation-capture.off)" % tag)
        return 0
    try:
        fh = open(cfg.lock, "a")
    except OSError as ex:
        print("%s NÃO consegui abrir a trava %s: %s" % (tag, cfg.lock, ex))
        return 3
    try:
        end = io.now() + (cfg.lock_wait_s if final else 0)
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if io.now() >= end:
                    print("%s outra instância em curso" % tag)
                    return 4
                io.sleep(0.5)
            except OSError as ex:
                print("%s NÃO consegui travar %s: %s" % (tag, cfg.lock, ex))
                return 3
        code, c = run_pass(cfg, io, final, dry)
    finally:
        fh.close()
    if code != 0:
        print("%s NÃO consegui avaliar (ver %s)" % (tag, cfg.log))
        return code
    print("%s alvos=%d gravou=%d igual=%d ausente=%d nao-sei=%d falhou=%d%s" % (tag, c["targets"], c["wrote"], c["same"], c["absent"], c["unknown"], c["failed"], " (dry-run)" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
