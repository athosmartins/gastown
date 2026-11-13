#!/usr/bin/env python3
"""login-rc-restore.py (ga-bw9hmzg): after a /login (or a bare /remote-control) the Mayor and the named crews come back in the Claude app with their FIXED Remote Control names.

WHY  /login inside a session prints "Login successful. Remote Control disconnected."; re-enabling it with a bare /remote-control gives a generated name. The fixed name (Mayor, Batista,
  Digo, Oracle, Peter, Mila, Thies) only comes from the launch flag `claude --remote-control <Name>` (providers in city.toml); `gc session kill <id>` makes the reconciler respawn the
  session with the provider args, so the name returns.
CONTRACT  each pass (launchd, every 60 s):
  1 EVENT  per live target, its transcript (~/.claude/projects/<cwd, non-alphanumerics -> '->/<sessionId>.jsonl) is read from the saved offset for ONLY two structural shapes:
    a user entry whose message.content STRING starts with <local-command-stdout> and says "Login successful", or a command entry (user message.content / system local_command
    top-level content) that STARTS with <command-name>/remote-control</command-name> with EMPTY <command-args>. The same words quoted in tool_use/tool_result/api blobs never count.
    First sight of a conversation = start at its end (history never triggers), unless its process started after the last pass (then from 0, entries older than the process ignored).
  2 The session that had the event is killed when its session-file status is "idle" (never "busy"), once per event, and only while it is still the very process that had it.
  3 For 30 min after ANY event, each target whose process started before the event: login/limit screen and status idle|waiting -> kill now; no bridgeSessionId and idle -> kill.
  4 20 min after an event: ONE `notify -p 4` per event listing every active target still wrong (no live claude, no bridge, login/limit screen, cmdline without
    `--remote-control <ExpectedName>`, or still the process that had the event). Silence when all are OK. A reading that is still unknown defers the alarm up to the 30-min mark.
  5 MAYOR GATE  the Mayor is only killed if .gc/login-rc-restore.mayor-on exists (wake_mode fresh until ga-esorlre.3: a restart loses its conversation); otherwise the log says
    "WOULD restart mayor (gate off)" once per event and step 4 reports it if it is still wrong.
THREE STATES  live (one claude under the pane, readable registry) / absent (tmux says no session, no claude under the pane) / unknown (tmux/ps/gc failed or timed out, unreadable file,
  two claudes in one pane, budget spent). Only a positive reading kills; unknown never does. Targets = active gastown.mayor + named crews (Layer-1 rule; pool workers out).
RUN  instance lock, budget LRR_BUDGET_S 45 (after `gc session list`, which has its own LRR_GC_TIMEOUT_S 60, as each kill); stdout = ONE summary line; decisions in .gc/logs/login-rc-restore.log; state (offsets, events, kills) in .gc/login-rc-restore.state.json.
  --dry-run takes no lock, writes no state/log (log lines go to stdout), kills nothing, notifies nothing.
KNOBS  LRR_ENABLED=0 or .gc/login-rc-restore.off (kill switch) · .gc/login-rc-restore.mayor-on (Mayor gate) · LRR_RUN_DIR (state/lock/log elsewhere) · LRR_HOME · LRR_CLAUDE_DIR ·
  LRR_GC · LRR_TMUX · LRR_TMUX_SOCKET · LRR_NOTIFY · LRR_BUDGET_S · LRR_WINDOW_S (1800) · LRR_ALARM_S (1200) · LRR_GC_TIMEOUT_S/LRR_SYS_TIMEOUT_S.
  EXIT 0 evaluated · 2 usage · 3 could not evaluate · 4 another instance runs.
ROLLBACK  touch .gc/login-rc-restore.off (next pass) or launchctl bootout gui/$(id -u)/com.gascity.login-rc-restore; the job only ever runs `gc session kill`, never edits sessions.
"""
import datetime
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
MAYORS = ("gastown.mayor", "mayor")
START_SLACK_S = 3
MAX_DEPTH = 8
MAX_READ = 16 << 20                   # bytes of one transcript read per pass; the rest is read on the next pass
EVENT_KEEP_S = 6 * 3600              # an event is forgotten after this (its kill of step 2 too)
COALESCE_S = 300                     # one alarm covers the events of one burst (/login then /remote-control seconds later)
NEEDLES = (b"Login successful", b"<command-name>/remote-control</command-name>", b"<command-name>/rc</command-name>")
CMD_RE = re.compile(r"<command-name>/(?:remote-control|rc)</command-name>")
ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.S)
# the stuck screen, only as the START of one of the last lines (a sentence that quotes it starts with a word)
SCREEN_RE = re.compile(r"^[^\w]*(?:\d+\.\s*)?(?:login expired|please run /login|not logged in|you['’]ve hit your\b.{0,40}\blimit\b|hit your\b.{0,40}\blimit\b|stop and wait for limit to reset)", re.I)
SCREEN_TAIL = 25
NOT_BUSY = ("idle", "waiting")       # "shell" (a ! command running) counts as busy: never killed under it
NOTIFY_OK = (0, 10, 11)

def num(v, default):
    try:
        return max(int(str(v).strip()), 0) or default
    except (TypeError, ValueError):
        return default

class Cfg:
    def __init__(self, env):
        g = env.get
        self.city = g("GC_CITY_PATH") or CITY_DEFAULT
        self.home = g("LRR_HOME") or os.path.expanduser("~")
        self.claude = g("LRR_CLAUDE_DIR") or os.path.join(self.home, ".claude")
        self.gc = [g("LRR_GC") or g("GC_BIN") or "gc", "--city", self.city]
        self.tmux = [g("LRR_TMUX") or "tmux", "-L", g("LRR_TMUX_SOCKET") or "gascity"]
        self.notify = g("LRR_NOTIFY") or "notify"
        self.budget_s, self.window_s, self.alarm_s = num(g("LRR_BUDGET_S"), 45), num(g("LRR_WINDOW_S"), 1800), num(g("LRR_ALARM_S"), 1200)
        self.gc_t, self.sys_t = num(g("LRR_GC_TIMEOUT_S"), 60), num(g("LRR_SYS_TIMEOUT_S"), 10)
        gc_dir = os.path.join(self.city, ".gc")
        run = g("LRR_RUN_DIR") or gc_dir
        self.agents, self.city_toml = os.path.join(self.city, "agents"), os.path.join(self.city, "city.toml")
        self.state, self.lock = os.path.join(run, "login-rc-restore.state.json"), os.path.join(run, "login-rc-restore.lock")
        self.log = os.path.join(run, "logs", "login-rc-restore.log") if run == gc_dir else os.path.join(run, "login-rc-restore.log")
        self.mayor_gate = os.path.join(gc_dir, "login-rc-restore.mayor-on")
        self.enabled = g("LRR_ENABLED", "1") != "0" and not os.path.exists(os.path.join(gc_dir, "login-rc-restore.off"))

class RealIO:
    now = staticmethod(time.time)

    def run(self, argv, timeout, env=None):
        """(rc, stdout, stderr); rc None = could not start or timed out: never an empty answer."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout,
                               env=dict(os.environ, **env) if env else None)
        except (OSError, subprocess.SubprocessError):
            return None, "", ""
        return p.returncode, p.stdout, p.stderr

class Log:
    def __init__(self, path, dry):
        self.path, self.dry = path, dry

    def __call__(self, msg):
        line = "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        if self.dry:
            return print(line)
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as ex:
            sys.stderr.write("WARN: cannot append to %s: %s\n" % (self.path, ex))

def crew_names(agents_dir):
    """Named crews (Layer-1 rule, as live-conversation-capture.py): work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1. None = unreadable."""
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

def rc_names(city_toml):
    """({provider: RC name | "" unnamed | None no RC}, Mayor's provider) from city.toml; None = unreadable."""
    try:
        with open(city_toml, encoding="utf-8") as fh:
            txt = fh.read()
    except OSError:
        return None
    names, mayor = {}, "claude-rc"
    for block in re.split(r"(?m)^(?=\[)", txt):
        h = re.match(r"\[providers\.([A-Za-z0-9_.-]+)\]", block)
        if h:
            a = re.search(r"^args_append\s*=\s*\[(.*?)\]", block, re.M | re.S)
            toks = re.findall(r'"([^"]*)"', a.group(1)) if a else []
            name = None
            if "--remote-control" in toks:
                i = toks.index("--remote-control") + 1
                name = toks[i] if i < len(toks) and not toks[i].startswith("-") else ""
            names[h.group(1)] = name
        elif block.startswith("[[patches.agent]]") and re.search(r'^name\s*=\s*"gastown\.mayor"', block, re.M):
            p = re.search(r'^provider\s*=\s*"([^"]+)"', block, re.M)
            mayor = p.group(1) if p else mayor
    return names, mayor

def agent_provider(agents_dir, tpl):
    try:
        with open(os.path.join(agents_dir, tpl, "agent.toml"), encoding="utf-8") as fh:
            m = re.search(r'^provider\s*=\s*"([^"]+)"', fh.read(), re.M)
    except OSError:
        return None
    return m.group(1) if m else None

def load_roster(io, cfg, tmo):
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
        tpl, tname, bead = s.get("template"), s.get("session_name") or s.get("name"), s.get("id")
        if not (isinstance(tpl, str) and isinstance(tname, str) and tname and isinstance(bead, str) and bead):
            continue
        mayor, base = tpl in MAYORS, tpl.rsplit("/", 1)[-1]
        if mayor or base in crews:
            out.append({"bead": bead, "tname": tname, "tpl": base, "mayor": mayor, "alias": "mayor" if mayor else (s.get("alias") or base)})
    return sorted(out, key=lambda t: (not t["mayor"], t["alias"]))

def parse_etime(s):
    m = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", s)
    return None if not m else int(m.group(1) or 0) * 86400 + int(m.group(2) or 0) * 3600 + int(m.group(3)) * 60 + int(m.group(4))

def ps_table(io, tmo):
    """{pid: (ppid, start epoch, args)}; None = ps unreadable (an empty table is unreadable too)."""
    rc, out, _ = io.run(["ps", "-ww", "-axo", "pid=,ppid=,etime=,args="], tmo)
    if rc != 0:
        return None
    t, tab = io.now(), {}
    for ln in out.splitlines():
        f = ln.split(None, 3)
        age = parse_etime(f[2]) if len(f) >= 3 and f[0].isdigit() and f[1].isdigit() else None
        if age is not None:
            tab[int(f[0])] = (int(f[1]), t - age, f[3] if len(f) == 4 else "")
    return tab or None

def descend(tab, roots):
    kids = {}
    for pid, v in tab.items():
        kids.setdefault(v[0], []).append(pid)
    seen, level = set(roots), list(roots)
    for _ in range(MAX_DEPTH):
        level = [k for p in level for k in kids.get(p, []) if k not in seen]
        seen.update(level)
    return seen

def read_entry(claude, pid, start):
    """("ok", entry) / ("none", None) / ("bad", why) for ~/.claude/sessions/<pid>.json of the live process that started at `start` (copied from live-conversation-capture.py)."""
    path = os.path.join(claude, "sessions", "%d.json" % pid)
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

def observe(io, cfg, tgt, tab, tmo):
    """dict(st=live|absent|unknown, why, pid, start, entry, pane, args) for one target."""
    rc, out, err = io.run(cfg.tmux + ["list-panes", "-s", "-t", "=%s:" % tgt["tname"], "-F", "#{pane_id} #{pane_pid}"], tmo)
    if rc is None:
        return {"st": "unknown", "why": "tmux did not answer"}
    if rc != 0:
        return {"st": "absent" if "can't find session" in (err or "") else "unknown", "why": "tmux rc=%d: %s" % (rc, (err or "").strip()[:80])}
    panes = [ln.split() for ln in out.splitlines() if len(ln.split()) == 2 and ln.split()[1].isdigit()]
    if not panes:
        return {"st": "unknown", "why": "tmux answered with no pane"}
    if tab is None:
        return {"st": "unknown", "why": "ps could not be read"}
    found = {}
    for pane, ppid in panes:
        for pid in descend(tab, [int(ppid)]):
            if pid not in tab:
                continue
            s, e = read_entry(cfg.claude, pid, tab[pid][1])
            if s == "bad":
                return {"st": "unknown", "why": e}
            if s == "ok":
                found[pid] = (e, pane)
    if not found:
        return {"st": "absent", "why": "no claude under the pane"}
    if len(found) > 1:
        return {"st": "unknown", "why": "%d claudes in one pane" % len(found)}
    pid, (e, pane) = next(iter(found.items()))
    return {"st": "live", "why": "", "pid": pid, "start": tab[pid][1], "entry": e, "pane": pane, "args": tab[pid][2]}

def screen(io, cfg, obs, tmo):
    """"stuck" / "clear" / "unknown" from the LAST lines of the pane (cached in obs)."""
    if "screen" not in obs:
        rc, out, _ = io.run(cfg.tmux + ["capture-pane", "-p", "-J", "-t", obs["pane"]], tmo)
        if rc != 0:
            obs["screen"] = "unknown"
        else:
            lines = [ln.strip() for ln in out.splitlines() if ln.strip()][-SCREEN_TAIL:]
            obs["screen"] = "stuck" if any(SCREEN_RE.search(ln) for ln in lines) else "clear"
    return obs["screen"]

def iso_s(v):
    try:
        return datetime.datetime.strptime(v.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
    except (AttributeError, ValueError):
        return None

def match_event(e):
    """"login" / "rc-unnamed" / None for ONE transcript entry: only the structural shapes of the header, never a quote."""
    if not isinstance(e, dict):
        return None
    if e.get("type") == "user":
        m = e.get("message")
        c = m.get("content") if isinstance(m, dict) else None
    elif e.get("type") == "system" and e.get("subtype") == "local_command":
        c = e.get("content")
    else:
        return None
    if not isinstance(c, str):
        return None
    s = c.lstrip()
    if s.startswith("<local-command-stdout>") and "Login successful" in s:
        return "login"
    if CMD_RE.match(s):
        a = ARGS_RE.search(s)
        if a and not a.group(1).strip():
            return "rc-unnamed"
    return None

def transcript_path(claude, entry):
    sid, cwd = entry["sessionId"], entry.get("cwd")
    if isinstance(cwd, str) and cwd:
        p = os.path.join(claude, "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")
        if os.path.exists(p):
            return p
    g = glob.glob(os.path.join(glob.escape(claude), "projects", "*", sid + ".jsonl"))
    return g[0] if len(g) == 1 else None

def scan(path, off, since):
    """("ok", [(kind, line offset)], new offset) / ("unknown", why, None). Reads complete lines only, at most MAX_READ bytes."""
    try:
        size = os.stat(path).st_size
        if off is None or size < off:
            return "ok", [], size
        with open(path, "rb") as fh:
            fh.seek(off)
            buf = fh.read(MAX_READ)
    except OSError as ex:
        return "unknown", "cannot read transcript: %s" % ex, None
    cut = buf.rfind(b"\n") + 1
    hits, pos = [], 0
    for raw in buf[:cut].split(b"\n")[:-1]:
        if any(n in raw for n in NEEDLES):
            try:
                e = json.loads(raw)
            except ValueError:
                e = None
            k = match_event(e)
            if k and not (since and (iso_s(e.get("timestamp")) or 0) < since):
                hits.append((k, off + pos))
        pos += len(raw) + 1
    return "ok", hits, off + cut

def load_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            s = json.load(fh)
    except (OSError, ValueError):
        return {}
    return s if isinstance(s, dict) else {}

def save_state(path, st):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh, sort_keys=True)
    os.replace(tmp, path)

def same_proc(e, obs):
    return obs.get("st") == "live" and obs["pid"] == e.get("pid") and abs(obs["start"] - e.get("start", 0)) <= START_SLACK_S + 1

def run_pass(cfg, io, dry=False):
    """-> (exit code, counts, target aliases)."""
    log = Log(cfg.log, dry)
    t0 = io.now()

    def left(cap):
        return max(1, min(cap, int(end - io.now())))
    c = dict.fromkeys(("events", "killed", "would", "alarms", "unknown"), 0)
    crews, prov = crew_names(cfg.agents), rc_names(cfg.city_toml)
    roster = None if crews is None or prov is None else load_roster(io, cfg, cfg.gc_t)
    end = io.now() + cfg.budget_s  # the budget counts after the roster: under load `gc session list` alone took 53-59 s (13/11, load 65)
    if roster is None:
        log("ERROR: cannot evaluate, nothing done: %s" % ("agents/ or city.toml unreadable" if crews is None or prov is None else "gc session list unreadable"))
        return 3, c, []
    names, mayor_prov = prov
    targets = pick_targets(roster, crews)
    tab = ps_table(io, left(cfg.sys_t)) if targets else {}
    st = load_state(cfg.state)
    offsets = st.get("offsets") if isinstance(st.get("offsets"), dict) else {}
    events = [e for e in st.get("events", []) if isinstance(e, dict) and t0 - e.get("ts", 0) < EVENT_KEEP_S] if isinstance(st.get("events"), list) else []
    kills = st.get("kills") if isinstance(st.get("kills"), dict) else {}
    last_pass = st.get("last_pass") if isinstance(st.get("last_pass"), (int, float)) else None
    gate = os.path.exists(cfg.mayor_gate)
    for t in targets:
        t["want"] = names.get(mayor_prov if t["mayor"] else agent_provider(cfg.agents, t["tpl"]))
        t["obs"] = {"st": "unknown", "why": "time budget of the pass spent"} if io.now() >= end else observe(io, cfg, t, tab, left(cfg.sys_t))
        o = t["obs"]
        if o["st"] == "unknown":
            c["unknown"] += 1
            log("UNKNOWN %s: %s — no action on it" % (t["alias"], o["why"]))
        if o["st"] != "live":
            continue
        e, sid = o["entry"], o["entry"]["sessionId"]  # 1. events from the transcript
        path = transcript_path(cfg.claude, e)
        if not path:
            continue
        rec = offsets.get(sid) if isinstance(offsets.get(sid), dict) else None
        if rec is None:  # first sight: from the end, or from 0 for a process born after the last pass
            started = (e.get("startedAt") or 0) / 1000.0
            rec = {"off": 0, "since": started} if last_pass is not None and started > last_pass else {"off": None}
        r, hits, new = scan(path, rec.get("off"), rec.get("since"))
        if r != "ok":
            log("UNKNOWN %s transcript: %s" % (t["alias"], hits))
            continue
        offsets[sid] = {"off": new, "since": rec.get("since"), "seen": int(t0)}
        for kind, at in hits:
            ev = {"id": "%s:%d" % (sid, at), "bead": t["bead"], "alias": t["alias"], "kind": kind, "ts": io.now(), "pid": o["pid"], "start": o["start"]}
            if all(x.get("id") != ev["id"] for x in events):
                events.append(ev)
                c["events"] += 1
                log("EVENT %s %s in %s (pid %d, offset %d)" % (kind, t["alias"], sid, o["pid"], at))
    now = io.now()
    for t in targets:  # 2 + 3: kills
        o = t["obs"]
        if o["st"] != "live":
            continue
        status, bridge = o["entry"].get("status"), o["entry"].get("bridgeSessionId")
        why = None
        for ev in sorted(events, key=lambda x: x["ts"], reverse=True):
            if kills.get(t["bead"], 0) >= ev["ts"] or o["start"] >= ev["ts"]:
                continue  # already restarted after this event, or born after it (fresh launch, fresh login)
            if ev["bead"] == t["bead"] and same_proc(ev, o) and status == "idle":
                why = "had the %s event and is idle" % ev["kind"]
            elif now - ev["ts"] < cfg.window_s and status in NOT_BUSY and screen(io, cfg, o, left(cfg.sys_t)) == "stuck":
                why = "login/limit screen, status %s, %d s after the event" % (status, now - ev["ts"])
            elif now - ev["ts"] < cfg.window_s and not bridge and status == "idle":
                why = "no Remote Control bridge and idle, %d s after the event" % (now - ev["ts"])
            if why:
                break
        if not why:
            continue
        if t["mayor"] and not gate:
            if t["bead"] not in ev.setdefault("would", []):
                ev["would"].append(t["bead"])
                log("WOULD restart mayor (gate off): %s — touch %s to allow it" % (why, cfg.mayor_gate))
            c["would"] += 1
            continue
        if dry:
            c["killed"] += 1
            log("WOULD kill %s (%s): %s (dry-run)" % (t["alias"], t["bead"], why))
            continue
        rc, _, err = io.run(cfg.gc + ["session", "kill", t["bead"]], cfg.gc_t)
        if rc == 0:
            kills[t["bead"]] = io.now()
            c["killed"] += 1
            log("KILLED %s (%s): %s — the reconciler respawns it with --remote-control %s" % (t["alias"], t["bead"], why, t["want"] or "(unnamed)"))
        else:
            log("FAILED kill %s (%s): rc=%s %s — retried next pass" % (t["alias"], t["bead"], rc, (err or "").strip()[:100]))
    pend = sorted((e for e in events if not e.get("alarm") and now - e["ts"] >= cfg.alarm_s), key=lambda x: x["ts"])
    if pend:  # 4: the alarm
        ev = pend[0]
        wrong, unk = [], []
        for t in targets:
            o, bad = t["obs"], []
            if o["st"] == "absent":
                bad.append("sem claude vivo")
            elif o["st"] == "unknown":
                unk.append("%s (não consegui ler: %s)" % (t["alias"], o["why"]))
                continue
            else:
                if not o["entry"].get("bridgeSessionId"):
                    bad.append("sem Remote Control")
                sc = screen(io, cfg, o, left(cfg.sys_t))
                if sc == "stuck":
                    bad.append("tela de login/limite")
                elif sc == "unknown":
                    unk.append("%s (tela ilegível)" % t["alias"])
                if t["want"] and not re.search(r"--remote-control %s(?= -|\s*$)" % re.escape(t["want"]), o["args"]):
                    bad.append("nome do RC não é %s" % t["want"])
                if any(x["bead"] == t["bead"] and same_proc(x, o) for x in events):
                    bad.append("não reiniciou depois do /login" + (" (gate do Mayor desligado)" if t["mayor"] and not gate else ""))
            if bad:
                wrong.append("%s: %s" % (t["alias"], ", ".join(bad)))
        if unk and now - ev["ts"] < cfg.window_s:
            log("ALARM deferred (unknown readings): %s" % "; ".join(unk))
        else:
            batch = [e for e in pend if e["ts"] - ev["ts"] <= COALESCE_S]
            if not wrong and not unk:
                log("ALL OK %d s after the %s event of %s: every target has its named Remote Control" % (now - ev["ts"], ev["kind"], ev["alias"]))
                for e in batch:
                    e["alarm"] = "ok"
            else:
                msg = "%d min depois do %s em %s, ainda errados: %s" % ((now - ev["ts"]) // 60, "/login" if ev["kind"] == "login" else "/remote-control sem nome",
                                                                      ev["alias"], "; ".join(wrong + unk))
                if dry:
                    log("WOULD notify: %s" % msg)
                    c["alarms"] += 1
                elif now - ev.get("alarm_try", 0) >= 600:
                    ev["alarm_try"] = now
                    rc, _, _ = io.run([cfg.notify, "-p", "4", "-t", "Remote Control: nomes fixos não voltaram", msg], 30, {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"})
                    log("ALARM %s: %s" % ("sent" if rc in NOTIFY_OK else "NOT delivered (notify rc=%s), retried in 10 min" % rc, msg))
                    if rc in NOTIFY_OK:
                        c["alarms"] += 1
                        for e in batch:
                            e["alarm"] = "sent"
    st = {"v": 1, "last_pass": t0, "events": events, "kills": {k: v for k, v in kills.items() if t0 - v < EVENT_KEEP_S},
          "offsets": {k: v for k, v in offsets.items() if isinstance(v, dict) and t0 - v.get("seen", 0) < 7 * 86400}}
    if not dry:
        try:
            save_state(cfg.state, st)
        except OSError as ex:
            log("WARN: cannot save %s: %s" % (cfg.state, ex))
    c["open"] = sum(1 for e in events if now - e["ts"] < cfg.window_s)
    return 0, c, [t["alias"] + ("" if t["obs"]["st"] == "live" else "(%s)" % t["obs"]["st"]) for t in targets]

def main(argv=None, env=None, io=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv not in ([], ["--dry-run"]):
        sys.stderr.write("usage: login-rc-restore.py [--dry-run]\n")
        return 2
    dry = bool(argv)
    cfg, io = Cfg(os.environ if env is None else env), io or RealIO()
    tag = "login-rc-restore:"
    if not cfg.enabled:
        print("%s desligado (LRR_ENABLED=0 ou .gc/login-rc-restore.off)" % tag)
        return 0
    fh = None
    if not dry:  # dry-run writes nothing, not even the lock file
        try:
            os.makedirs(os.path.dirname(cfg.lock), exist_ok=True)
            fh = open(cfg.lock, "a")
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("%s outra instância em curso" % tag)
            fh.close()
            return 4
        except OSError as ex:
            print("%s NÃO consegui travar %s: %s" % (tag, cfg.lock, ex))
            return 3
    try:
        code, c, tg = run_pass(cfg, io, dry)
    finally:
        if fh:
            fh.close()
    if code != 0:
        print("%s NÃO consegui avaliar (ver %s)" % (tag, cfg.log))
        return code
    print("%s alvos=%d [%s] eventos-novos=%d janela-aberta=%d reiniciou=%d mayor-gate-off=%d alarmes=%d nao-sei=%d%s" % (
        tag, len(tg), ",".join(tg), c["events"], c["open"], c["killed"], c["would"], c["alarms"], c["unknown"], " (dry-run)" if dry else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main())
