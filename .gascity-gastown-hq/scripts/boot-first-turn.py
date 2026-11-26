#!/usr/bin/env python3
"""boot-first-turn.py (ga-esorlre.13, layer 1 of ga-esorlre.12): the Mayor and every named crew get a REAL first turn when their claude comes up, typed into the pane, so a session never waits at its prompt for a human.

WHY  25-26/11: after the 23:42 reboot peter-wa and oracle-wa came back on a NEW conversation and sat at the prompt for 6-8 h. Everything sent to an idle session through `gc session nudge` (the resume notice, four Pilot dispatches) became a
  "deferred reminder queued until a safe boundary": it is delivered only when a turn starts, and an idle session has none. Only input typed into the pane wakes it. (Athos 26/11: "pecado capital, não pode acontecer em hipótese alguma".)
WHAT  Targets: the active gastown.mayor + the named crews (the Layer-1 rule of crew-idle-check.sh; pool workers, dogs and reviewers are out). Per target, the ONE live interactive claude of its tmux session (~/.claude/sessions/<pid>.json + ps).
  When it came up <= BFT_WINDOW_S (20 min) ago, has been idle >= BFT_IDLE_S (120 s by the registry status; twice that of transcript quiet when the registry has no status field) and its pane (tmux capture-pane) is an idle Claude prompt with an EMPTY input box
  (the `Try "..."` suggestion of a conversation with no turn yet is not a draft), the job types ONE line: tmux send-keys -l, then Enter in a separate call. The line starts with TAG and keeps the Mayor's wording: "retome a bead em andamento <ids> e o último
  handoff; se não houver, pegue a próxima por prioridade". <ids> = the in_progress beads whose assignee is the session (its tmux name, its alias, or an earlier incarnation `<alias>-gawisp<tail>`: a boot gives the crew a new session name and its
  bead keeps the old one), read from the city store and the crew's rig store. A store that cannot be read adds nothing and the line still goes, saying "a bead que estiver em andamento com você": it never claims there is none.
  Once per START: the record is (pid, process start). Another pid, or a start more than 30 s apart, is a new start, so a reboot that hands the old pid to the new claude still gets its line.
PROOF  On the next pass (60 s): a turn started when the registry shows busy/waiting or a status change after the typing, or the transcript has a user record with the TAG after the offset taken at the typing, or the pane shows work, or the
  conversation changed. No proof BFT_RETRY_S (90) after the typing: ONE retry, only where it is safe. An idle empty pane gets the line again; OUR line still sitting in the input box gets Enter alone; a person's draft, a dialog or a pane that cannot be
  read get nothing. No proof BFT_GIVE_UP_S (240) after that: UNCONFIRMED (log ERROR, a line in the jsonl, ONE `notify -p 4`, retried on up to 3 passes) and the start is not touched again. A lost record is no reason to type twice: the transcript already
  carrying the TAG since this process started counts as done (the TAG a resumed conversation inherited from an earlier boot does not).
THREE STATES  Every read has them, has / has-not / could-not-tell, and could-not-tell is inert. Nothing is typed when the registry, the roster (bd query, then gc session list), ps or tmux did not answer, when two claudes share a pane, when the pane cannot be
  read, or when the kill switch cannot be read. A typing that failed is not recorded as sent; one whose Enter failed is (the line waits in the input box for the retry). The sign of life is never taken from a read that failed.
RUN  launchd every 60 s (RunAtLoad; instance lock; budget BFT_BUDGET_S 100) and `--dry-run` (reads everything; types, notifies and writes nothing; log lines go to stdout). A pass with nothing started inside the window and nothing to follow up leaves before any
  bd, gc, ps or tmux call and writes no log line: that is the steady state, every crew being days old. stdout = ONE summary line; events in .gc/logs/boot-first-turn.log (a reading that does not change is told once); outcomes in
  .gc/logs/boot-first-turn.jsonl (result confirmed|unconfirmed, via tmux|tmux+retry|tmux+enter, how = the sign of life); the records in .gc/boot-first-turn.state.json. Reads and types through tmux (-L gascity, the city's server) and never through `gc session
  peek/nudge`, which took 22-60 s under the boot load. The neighbours: crew-idle-wake (ga-esorlre.14) wakes a session idle for more than 10 min with work in progress, and ga-esorlre.15 proves at 00:10 that each crew moved; this job is the one that fires in the first minutes.
KNOBS  BFT_ENABLED=0 or .gc/boot-first-turn.off (an unreadable .off counts as off) · BFT_WINDOW_S · BFT_IDLE_S · BFT_RETRY_S · BFT_GIVE_UP_S · BFT_BUDGET_S · BFT_BD_TIMEOUT_S / BFT_GC_TIMEOUT_S / BFT_SYS_TIMEOUT_S · BFT_HOME · BFT_GC · BFT_BD ·
  BFT_TMUX · BFT_TMUX_SOCKET (gascity) · BFT_NOTIFY · GC_CITY_PATH.  EXIT 0 evaluated · 2 usage · 3 could not evaluate · 4 another instance runs.
LIVE  Written and tested off the mini; what is not proven there, and how to check it on the first reboot, is in docs/runbooks/boot-primeiro-turno.md.
"""
import calendar
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

CITY_DEFAULT = "/Users/athos/gt/.gascity-gastown-hq"
MAYORS = ("gastown.mayor", "mayor")
NOTIFY_OK = (0, 10, 11)  # notify's own codes for delivered (login-rc-restore.py reads them the same way)
NOTIFY_TRIES = 3
TAIL_BYTES = 4 << 20  # how much of a transcript's end the dedup reads
SAME_START_S = 30  # two readings of one process's start differ by seconds (ps etime has 1 s resolution): further apart than this it is another process
FRESH_MARGIN_S = 300  # the registry's startedAt only decides whether a pass is worth running (the start that counts is ps's): a claude that old PLUS this much slack is not looked at
PHASES = ("sent", "confirmed", "gave-up")
PENDING_MAX_S = 3600  # a start still waiting for its proof, or an alarm still waiting to get through, that is older than this is not waited for any more
PRUNE_AFTER_S = 7 * 86400  # a record is forgotten by AGE (a session that flickers out of the roster for a pass must keep its record: it is what stops a second typing)
COUNTS = ("targets", "typed", "confirmed", "pending", "unconfirmed", "wait", "late", "unknown", "absent")
START_SLACK_S = 3  # ps etime has 1 s resolution: a registry file may look this much older than its process and still be its own
TAG = "[ga-esorlre.13 primeiro turno do boot]"  # what the proof looks for in the transcript; the text starts with it
MAX_IDS = 5
SAFE_ID = re.compile(r"[A-Za-z0-9._-]{1,48}")  # a bead id is typed into a terminal: nothing else gets through
DUR = r"([0-9]+h[ \t]+)?([0-9]+m[ \t]+)?[0-9]+s"
GLYPH = r"(✻|✽|✳|✶|✢|✺|✹|·|\*)"
DIALOG_RE = re.compile(r"Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel")
BUSY_RE = re.compile(r"(…|\.\.\.)[^(]*\(" + DUR + "|esc to interrupt")
SPIN_RE = re.compile(r"^\s*" + GLYPH + r"\s+\S+(…|\.\.\.)", re.M)
# not agents: the mini's claude draws `· ← 1 agent` on every pane captured there, idle or busy (ga-esorlre.10), so only shells/tasks/monitors count as work in the footer
FOOT_RE = re.compile(r"\b\d+ (?:shells?|bash(?:es)?|tasks?|monitors?)\b")
MENU_RE = re.compile(r"^\s*❯\s*\d+\.\s")
PLACEHOLDER_RE = re.compile(r'^Try ".*"$')  # the dim suggestion of a conversation with no turn yet, whole line only
ETIME_RE = re.compile(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)")
RIG_RE = re.compile(r"(.+)/crew/[^/]+")


def prompt_line(text):
    """the last line of the pane that starts with the Claude prompt mark, or None."""
    lines = [x.rstrip() for x in text.splitlines() if x.strip()]
    return next((x for x in reversed(lines) if x.lstrip().startswith("❯")), None), lines


def draft_of(text):
    """what sits after the prompt mark ('' = an empty input box); None = no Claude prompt in view."""
    prompt, _ = prompt_line(text)
    return None if prompt is None else prompt.lstrip()[1:].strip()


def read_pane(text):
    """(state, why): idle = a Claude prompt with nothing running, no dialog, an EMPTY input box and no background work in the footer.
    Other states: working (a turn runs) · busy (a draft in the input box, background work) · dialog · unknown. Built on the pane reading of nightly-session-compact.py (same dialog, busy, spinner and footer patterns); two additions of this file:
    a numbered menu is a dialog, and the `Try "..."` suggestion of a conversation with no turn yet is an empty box."""
    prompt, lines = prompt_line(text)
    if DIALOG_RE.search("\n".join(lines[-12:])):
        return "dialog", "a dialog waits for a key"
    if BUSY_RE.search(text):
        return "working", "a turn is running"
    if SPIN_RE.search(text):
        return "unknown", "a spinner whose timer cannot be read"
    if prompt is None:
        return "unknown", "no Claude Code prompt in view"
    if MENU_RE.match(prompt):
        return "dialog", "a numbered menu waits for a key"
    draft = prompt.lstrip()[1:].strip()
    if draft and not PLACEHOLDER_RE.match(draft):
        return "busy", "the input box holds text: %r" % draft[:40]
    foot = next((x for x in lines[-3:] if "·" in x and FOOT_RE.search(x)), None)
    if foot:
        return "busy", "background work in the footer: %s" % foot.strip()[:80]
    return "idle", ""


def compose(ids):
    """the ONE line typed as the first turn. `ids` = in_progress beads found for this session; an empty list means none found OR could not read, so the text never claims there is none."""
    safe = []
    for i in ids or []:
        if isinstance(i, str) and SAFE_ID.fullmatch(i) and i not in safe:
            safe.append(i)
    quem = "a bead em andamento %s" % ", ".join(safe[:MAX_IDS]) if safe else "a bead que estiver em andamento com você (confira com bd list --status in_progress)"
    return ("%s Sua sessão acabou de subir e ninguém vai te acordar: retome %s e o último handoff; se não houver, pegue a próxima por prioridade. "
            "Siga até terminar; se travar, registre na bead (comentário e next-action) em vez de ficar parado." % (TAG, quem))


def parse_etime(s):
    # vazio/ilegível (não é [[dd-]hh:]mm:ss) → None: quem chama trata como "não sei há quanto o processo existe"
    m = ETIME_RE.fullmatch(str(s).strip())
    return None if not m else int(m.group(1) or 0) * 86400 + int(m.group(2) or 0) * 3600 + int(m.group(3)) * 60 + int(m.group(4))


def rig_of(work_dir):
    """the rig (a bd store) of a crew work_dir `<rig>/crew/<slug>`; None when it is not one."""
    m = RIG_RE.fullmatch(work_dir) if isinstance(work_dir, str) else None
    return m.group(1) if m else None


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
        self.home = g("BFT_HOME") or os.path.expanduser("~")
        self.claude = os.path.join(self.home, ".claude")
        self.gc = [g("BFT_GC") or g("GC_BIN") or "gc", "--city", self.city]
        self.bd_bin = g("BFT_BD") or g("BD_BIN") or "bd"
        self.bd = [self.bd_bin, "-C", self.city]
        self.tmux = [g("BFT_TMUX") or "tmux", "-L", g("BFT_TMUX_SOCKET") or "gascity"]
        self.notify = g("BFT_NOTIFY") or "notify"
        self.window_s, self.idle_s = num(g("BFT_WINDOW_S"), 1200), num(g("BFT_IDLE_S"), 120)
        self.retry_s, self.give_up_s, self.budget_s = num(g("BFT_RETRY_S"), 90), num(g("BFT_GIVE_UP_S"), 240), num(g("BFT_BUDGET_S"), 100)
        self.gc_t, self.bd_t, self.sys_t = num(g("BFT_GC_TIMEOUT_S"), 45), num(g("BFT_BD_TIMEOUT_S"), 30), num(g("BFT_SYS_TIMEOUT_S"), 10)
        gc_dir = os.path.join(self.city, ".gc")
        self.agents, self.state = os.path.join(self.city, "agents"), os.path.join(gc_dir, "boot-first-turn.state.json")
        self.lock, self.off_file = os.path.join(gc_dir, "boot-first-turn.lock"), os.path.join(gc_dir, "boot-first-turn.off")
        self.log, self.jsonl = os.path.join(gc_dir, "logs", "boot-first-turn.log"), os.path.join(gc_dir, "logs", "boot-first-turn.jsonl")
        self.enabled = g("BFT_ENABLED", "1") != "0"


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
    def __init__(self, cfg, dry):
        self.path, self.jsonl, self.dry = cfg.log, cfg.jsonl, dry

    def _append(self, path, line):
        # falhou (diretório ausente, disco cheio) → aviso no stderr e segue: o log não é condição para digitar
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as ex:
            sys.stderr.write("WARN: cannot append to %s: %s\n" % (path, ex))

    def __call__(self, msg):
        line = "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        if self.dry:
            print(line)
        else:
            self._append(self.path, line)

    def record(self, rec):
        rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        if not self.dry:
            self._append(self.jsonl, json.dumps(rec, ensure_ascii=False, sort_keys=True))


def crew_templates(agents_dir):
    """-> (template -> work_dir of every named crew, [agent dirs whose agent.toml could not be read]); a crew has work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1 (the Layer-1 rule of crew-idle-check.sh). (None, []) = the dir could not be read."""
    # vazio (nenhuma crew) → ({}, []): só o Mayor é alvo; diretório agents/ sem leitura → (None, []): quem chama avisa e segue só com o Mayor; pasta sem agent.toml → não é crew; agent.toml que existe mas não se lê → vai na lista de ilegíveis: dita no log, nunca «não é crew» calado
    try:
        names = sorted(os.listdir(agents_dir))
    except OSError:
        return None, []
    out, bad = {}, []
    for n in names:
        try:
            with open(os.path.join(agents_dir, n, "agent.toml"), encoding="utf-8") as fh:
                txt = fh.read()
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            bad.append(n)
            continue
        wd, mx = re.search(r'^work_dir\s*=\s*"([^"]*)"', txt, re.M), re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        slug = re.search(r"/crew/([^/]+)$", wd.group(1)) if wd else None
        if slug and slug.group(1) != "worker" and not (mx and int(mx.group(1)) > 1):
            out[n] = wd.group(1)
    return out, bad


def load_roster_bd(io, cfg, tmo):
    """the active sessions from the session beads themselves (`bd query`: ~5 s where `gc session list` takes 22-60 s on a loaded mini); state awake/active = active, as the gc projection does."""
    # vazio (nenhuma bead de sessão aberta) → []: nenhum alvo; falhou/ilegível (rc≠0, estouro, JSON ruim, não-lista) → None: quem chama tenta o gc
    rc, out, _ = io.run(cfg.bd + ["query", "--json", "type=session AND status!=closed", "--limit=0"], tmo)
    if rc != 0:
        return None
    try:
        rows = json.loads(out)
    except ValueError:
        return None
    if not isinstance(rows, list):
        return None
    ros = []
    for b in rows:
        m = b.get("metadata") if isinstance(b, dict) else None
        if isinstance(m, dict) and isinstance(b.get("id"), str):  # a malformed row is skipped, never an exception that blinds the whole pass
            ros.append({"id": b["id"], "template": m.get("template"), "session_name": m.get("session_name"), "state": "active" if m.get("state") in ("active", "awake") else m.get("state")})
    return ros


def load_roster(io, cfg, tmo):
    # vazio (sessions: []) → []: nenhum alvo; falhou/ilegível (rc≠0, estouro, JSON ruim, "sessions" ausente ou não-lista) → None: com o bd query também sem resposta, o passe sai 3 sem digitar
    rc, out, _ = io.run(cfg.gc + ["session", "list", "--json"], tmo)
    if rc != 0:
        return None
    try:
        s = json.loads(out).get("sessions")
    except (ValueError, AttributeError):
        return None
    return s if isinstance(s, list) else None


def pick_targets(roster, crews):
    """the Mayor + the named crews whose session is active; pool workers, dogs and reviewers are out. -> [{bead, name (the tmux session), template, work_dir}] by name."""
    out = []
    for s in roster:
        if not isinstance(s, dict) or s.get("state") != "active":
            continue
        tpl, name, bead = s.get("template"), s.get("session_name") or s.get("name"), s.get("id")
        if not (isinstance(tpl, str) and isinstance(name, str) and name and isinstance(bead, str) and bead):  # a malformed row is skipped, never an exception that blinds the whole pass
            continue
        short = tpl.rsplit("/", 1)[-1]
        if tpl in MAYORS:
            out.append({"bead": bead, "name": name, "template": tpl, "work_dir": None})
        elif short in (crews or {}):
            out.append({"bead": bead, "name": name, "template": short, "work_dir": crews[short]})
    return sorted(out, key=lambda t: t["name"])


def load_registry(home):
    """(entries, unreadable_count); entries None = the registry dir could not be read."""
    # vazio (nenhum .json) → ([], 0): nenhum claude vivo; falhou (diretório ausente/sem leitura) → (None, 0): sem registro não há como provar nada; arquivo ruim → contado, nunca vira entrada
    d = os.path.join(home, ".claude", "sessions")
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return None, 0
    out, bad = [], 0
    for n in names:
        path = os.path.join(d, n)
        try:
            with open(path, encoding="utf-8") as fh:
                e = json.load(fh)
            mt = os.stat(path).st_mtime
        except (OSError, ValueError):
            bad += 1
            continue
        if isinstance(e, dict) and isinstance(e.get("sessionId"), str) and isinstance(e.get("pid"), int) and not isinstance(e.get("pid"), bool):
            e["_mtime"] = mt
            out.append(e)
        else:
            bad += 1
    return out, bad


def tmux_name(e):
    t = e.get("tmux")
    return t.split(":", 1)[0] if isinstance(t, str) and ":" in t else None


def proc_info(io, pid, tmo):
    """("alive", start epoch) / ("dead", why) / ("unknown", why): the pid exists AND its command names claude (a recycled pid is someone else's)."""
    # vazio (rc 1 sem saída: o ps não acha o pid) → dead; falhou (ps sem rodar, estouro, outro rc, saída que não leio) → unknown: não sei não é "morreu"
    rc, out, _ = io.run(["ps", "-o", "etime=,command=", "-p", str(pid)], tmo)
    if rc is None:
        return "unknown", "ps did not answer (timeout or not runnable)"
    if rc == 1 and not out.strip():
        return "dead", "no process %d" % pid
    parts = out.strip().split(None, 1)
    age = parse_etime(parts[0]) if parts else None
    if rc != 0 or age is None or len(parts) < 2:
        return "unknown", "ps rc=%s with an answer that cannot be read: %r" % (rc, out.strip()[:60])
    if "claude" not in parts[1].lower():
        return "dead", "pid %d is not claude (%s)" % (pid, parts[1][:40])
    return "alive", io.now() - age


def match_entry(io, t, registry, tmo):
    """("ok", {entry, start}) / ("absent", why) / ("unknown", why): the ONE live interactive claude of the target (its tmux session name, else the crew's work_dir)."""
    cand = [e for e in registry if e.get("kind") in (None, "interactive") and (tmux_name(e) == t["name"] or (tmux_name(e) is None and t["work_dir"] and e.get("cwd") == t["work_dir"]))]
    alive = []
    for e in cand:
        st, val = proc_info(io, e["pid"], tmo)
        if st == "unknown":
            return "unknown", val
        if st == "dead" or e["_mtime"] < val - START_SLACK_S:  # dead, or the file is older than its process: a leftover of an earlier holder of the pid (a reboot leaves them)
            continue
        alive.append((e, val))
    if not alive:
        return "absent", "no live claude registered for %s" % t["name"]
    if len(alive) > 1:
        return "unknown", "%d live claude processes match %s (pids %s)" % (len(alive), t["name"], ",".join(str(e["pid"]) for e, _ in alive))
    return "ok", {"entry": alive[0][0], "start": alive[0][1]}


def find_transcript(claude, sid):
    """path of <sid>.jsonl or None."""
    # vazio (nenhum arquivo) → None: a conversa ainda não tem transcript; diretório sem leitura também dá None (o glob engole o erro): nos dois nada se conclui dele
    hits = sorted(glob.glob(os.path.join(glob.escape(claude), "projects", "*", sid + ".jsonl")))
    return hits[0] if hits else None


def peek(io, cfg, name, tmo):
    """(state, why, pane text): the pane read straight from tmux (no supervisor call: `gc session peek` took 22-60 s under the boot load)."""
    # vazio (pane sem texto) → read_pane diz unknown "no Claude Code prompt"; falhou (rc≠0, estouro, sessão tmux inexistente) → unknown: ninguém digita num pane que não se leu
    rc, out, err = io.run(cfg.tmux + ["capture-pane", "-p", "-t", "=%s:" % name, "-S", "-40"], tmo)
    if rc is None:
        return "unknown", "tmux did not answer (timeout or not runnable)", ""
    if rc != 0:
        return "unknown", "tmux rc=%d: %s" % (rc, (err or "").strip()[:80]), ""
    state, why = read_pane(out)
    return state, why, out


def assess(io, cfg, t, m, now, tmo):
    """(verdict, why, pane text); verdict = ready | wait | late | unknown. Cheap checks first, the pane last."""
    e, start = m["entry"], m["start"]
    if now - start > cfg.window_s:
        return "late", "up for more than the %ds boot window: the idle watchdog owns it now" % cfg.window_s, ""
    status, sa = e.get("status"), e.get("statusUpdatedAt")
    need = cfg.idle_s
    if status is None:  # an older claude with no status field: quiet means a transcript untouched for twice the minimum
        need *= 2
        path = find_transcript(cfg.claude, e["sessionId"])
        try:
            since = max(start, os.stat(path).st_mtime) if path else start
        except OSError:
            return "unknown", "the transcript of %s cannot be read" % e["sessionId"], ""
    elif status != "idle":
        return "wait", "registry status=%s" % status, ""
    else:
        since = max(start, sa / 1000.0) if isinstance(sa, (int, float)) and not isinstance(sa, bool) else start  # idle since it came up when the status never changed
    if now - since < need:
        return "wait", "idle for only %ds (needs %ds)" % (now - since, need), ""
    state, why, text = peek(io, cfg, t["name"], tmo)
    return ("ready" if state == "idle" else "unknown" if state == "unknown" else "wait"), ("" if state == "idle" else "pane: " + why), text


def type_line(io, cfg, name, text, tmo):
    """("done" | "text-failed" | "enter-failed", why): the text as literal keys, then Enter in a SEPARATE call after a pause, as agent-stuck-escalation.sh and nightly-session-compact.py do. enter-failed leaves our text in the input box."""
    rc, _, err = io.run(cfg.tmux + ["send-keys", "-t", "=%s:" % name, "-l", text], tmo)
    if rc != 0:
        return "text-failed", "tmux send-keys (text) rc=%s: %s" % (rc, (err or "").strip()[:80])
    io.sleep(1.0)
    rc, _, err = io.run(cfg.tmux + ["send-keys", "-t", "=%s:" % name, "Enter"], tmo)
    return ("done", "") if rc == 0 else ("enter-failed", "tmux send-keys (Enter) rc=%s: %s" % (rc, (err or "").strip()[:80]))


def press_enter(io, cfg, name, tmo):
    rc, _, err = io.run(cfg.tmux + ["send-keys", "-t", "=%s:" % name, "Enter"], tmo)
    return rc == 0, "tmux send-keys (Enter) rc=%s: %s" % (rc, (err or "").strip()[:80])


def parse_ts(v):
    # vazio/ilegível (não é AAAA-MM-DDTHH:MM:SS) → None: quem chama não conta o registro como prova de nada
    try:
        return calendar.timegm(time.strptime(str(v)[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def parse_lines(data):
    out = []
    for ln in data.split(b"\n"):
        try:
            r = json.loads(ln) if ln.strip() else None
        except ValueError:
            continue
        if isinstance(r, dict):
            out.append(r)
    return out


def text_of(r):
    c = (r.get("message") or {}).get("content") if isinstance(r.get("message"), dict) else None
    if isinstance(c, list):
        c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return c if isinstance(c, str) else ""


def has_tag(recs, since=None):
    """True when a user record carries our line; with `since`, only one stamped at or after it (a record whose time cannot be read proves nothing about this start)."""
    for r in recs:
        if r.get("type") != "user" or TAG not in text_of(r):
            continue
        if since is not None:
            ts = parse_ts(r.get("timestamp"))
            if ts is None or ts < since:
                continue
        return True
    return False


def tail_records(path):
    """the records of the last TAIL_BYTES of a transcript (a cut first line does not parse and is ignored); None = unreadable."""
    # vazio (arquivo sem registro) → []; falhou (OSError) → None: quem chama digita (o pior caso é UMA linha repetida), nunca conclui "já foi"
    try:
        with open(path, "rb") as fh:
            size = fh.seek(0, os.SEEK_END)
            fh.seek(max(0, size - TAIL_BYTES))
            data = fh.read()
    except OSError:
        return None
    return parse_lines(data)


def new_records(path, offset):
    """(records, new offset) of the COMPLETE lines after `offset`; None = unreadable. A file that shrank (rewritten) is read from the start."""
    # vazio (nada novo) → ([], offset); falhou (OSError) → None: o prazo decide, nunca "confirmado"
    try:
        with open(path, "rb") as fh:
            if offset > os.fstat(fh.fileno()).st_size:
                offset = 0
            fh.seek(offset)
            data = fh.read()
    except OSError:
        return None
    cut = data.rfind(b"\n") + 1
    return parse_lines(data[:cut]), offset + cut


def valid_rec(r):
    def number(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return r.get("phase") in PHASES and isinstance(r.get("pid"), int) and not isinstance(r.get("pid"), bool) and number(r.get("start")) and number(r.get("sent_at")) and isinstance(r.get("sid"), str)


def load_state(path):
    # vazio (arquivo ausente) → ({}, {}): nada gravado ainda; falhou/ilegível (JSON ruim, formato errado) → ({}, {}); registro com campo faltando ou de tipo errado → descartado, sem derrubar o passe: o pior caso é UMA digitação a mais numa sessão ainda na janela, e o transcript a evita (a nossa linha desde o início conta como feita)
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        t, n = d.get("targets"), d.get("notes")
    except (OSError, ValueError, AttributeError):
        return {}, {}
    targets = {k: v for k, v in t.items() if isinstance(v, dict) and valid_rec(v)} if isinstance(t, dict) else {}
    for r in targets.values():
        if isinstance(r.get("typed_at"), bool) or not isinstance(r.get("typed_at"), (int, float)):
            r["typed_at"] = r["sent_at"]
        if not isinstance(r.get("ids"), list):
            r["ids"] = []
    return targets, ({k: v for k, v in n.items() if isinstance(v, str)} if isinstance(n, dict) else {})


def save_state(path, targets, notes):
    tmp = "%s.tmp%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"v": 1, "targets": targets, "notes": notes}, fh, sort_keys=True)
    os.replace(tmp, path)


def maybe_fresh(e, now, window_s):
    """False only when the registry says this claude started long before the window; a start that cannot be read does not hide the session."""
    # vazio/ilegível (sem startedAt, texto, bool) → True: na dúvida o passe roda e quem decide é o ps
    sa = e.get("startedAt")
    if isinstance(sa, (int, float)) and not isinstance(sa, bool):
        return now - sa / 1000.0 <= window_s + FRESH_MARGIN_S
    return True


def has_pending(state, now):
    """a start still waiting for its proof, or a give-up whose alarm has not got through yet, and recent enough to be worth waiting for: the boot window does not end these."""
    for r in state.values():
        if r.get("phase") == "sent" and now - r["sent_at"] <= PENDING_MAX_S:
            return True
        if r.get("phase") == "gave-up" and not r.get("notified") and r.get("notify_tries", 0) < NOTIFY_TRIES and now - r.get("gave_up_at", r["sent_at"]) <= PENDING_MAX_S:
            return True
    return False


def same_start(rec, pid, start):
    return rec.get("pid") == pid and isinstance(rec.get("start"), (int, float)) and abs(rec["start"] - start) <= SAME_START_S


class Ctx:
    """what one pass carries: the config, the IO, the log, the time budget, the bead reads and the readings already told."""
    def __init__(self, cfg, io, dry, notes):
        self.cfg, self.io, self.dry, self.log, self.notes = cfg, io, dry, Log(cfg, dry), notes
        self.end = io.now() + cfg.budget_s
        self.stores = {}  # in_progress beads per bd store, read once per pass

    def left(self, cap):  # each call gets what is left of the pass budget, never less than 1 s
        return max(1, min(cap, int(self.end - self.io.now())))

    def note(self, key, line):  # a reading that does not change is told once, not every minute
        if self.notes.get(key) != line:
            self.log(line)
            self.notes[key] = line


def in_progress(c, store):
    """the in_progress beads of one bd store, read ONCE per pass (a failed read is remembered too); None = unreadable."""
    if store not in c.stores:
        # vazio ([]) → []: ninguém tem bead em andamento ali; falhou/ilegível (rc≠0, estouro, JSON ruim, não-lista) → None: nada daquele store entra na linha, e a linha nunca afirma que não há
        rc, out, _ = c.io.run([c.cfg.bd_bin, "-C", store, "list", "--status", "in_progress", "--json", "--limit", "0"], c.left(min(c.cfg.bd_t, 15)))
        got = None
        if rc == 0:
            try:
                j = json.loads(out)
            except ValueError:
                j = None
            got = [b for b in j if isinstance(b, dict)] if isinstance(j, list) else None
        c.stores[store] = got
    return c.stores[store]


def owns(t, assignee):
    """does this assignee name the session? Its tmux name, its alias (the template), or an earlier incarnation `<alias>-gawisp<tail>`: a boot gives the crew a new session name and its bead keeps the old one."""
    a = assignee.rstrip("/") if isinstance(assignee, str) else ""
    names = {t["name"], t["template"]} | ({"mayor", "gastown.mayor"} if t["template"] in MAYORS else set())
    return bool(a) and (a in names or any(re.fullmatch(re.escape(n) + r"-gawisp[a-z0-9]+", a) for n in names))


def ids_for(c, t):
    """-> (the in_progress beads that are this session's, the stores that could not be read): the city store and, for a crew, its rig store (a crew's beads live in the rig). A store that cannot be read adds no bead and is NAMED, so the log tells "none found" from "could not look"; the line typed is the same for both."""
    stores = [c.cfg.city]
    rig = rig_of(t["work_dir"])
    if rig and rig != c.cfg.city:
        stores.append(rig)
    ids, unread = set(), []
    for store in stores:
        got = in_progress(c, store)
        if got is None:
            unread.append(store)
            continue
        for b in got:
            if isinstance(b.get("id"), str) and owns(t, b.get("assignee")):
                ids.add(b["id"])
    return sorted(ids), unread


def result_record(t, rec, result):
    return {"target": t["name"], "bead": t["bead"], "template": t["template"], "pid": rec["pid"], "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(rec["start"])),
            "session_id": rec["sid"], "result": result, "via": rec.get("via"), "how": rec.get("how"), "retried": bool(rec.get("retried")), "ids": rec.get("ids", [])}


def proof(c, t, e, rec):
    """(True, how, None) | (False, why, pane): did a turn start since the typing? Cheapest sign first: the registry, then the transcript, then the pane."""
    # vazio (nenhum sinal) → (False, …): segue pendente, o prazo decide; falhou/ilegível (transcript sem leitura, pane sem leitura) → também sem sinal: NUNCA vira "confirmado"
    if e.get("sessionId") != rec.get("sid"):
        return True, "conversation", None  # somebody switched conversation inside the session: a person is at it
    sa = e.get("statusUpdatedAt")
    if e.get("status") in ("busy", "waiting") or (isinstance(sa, (int, float)) and not isinstance(sa, bool) and sa / 1000.0 > rec["sent_at"]):
        return True, "registry", None
    path = rec.get("path") or find_transcript(c.cfg.claude, rec["sid"])
    got = new_records(path, rec.get("offset", 0)) if path else None
    if got is not None:
        rec["path"], rec["offset"] = path, got[1]
        if has_tag(got[0]):
            return True, "transcript", None
    state, why, text = peek(c.io, c.cfg, t["name"], c.left(c.cfg.sys_t))
    if state == "working":
        return True, "pane", None
    return False, "no sign of life (pane: %s)" % (why or state), (state, text)


def notify_gave_up(c, t, rec, now):
    if rec.get("notified") or rec.get("notify_tries", 0) >= NOTIFY_TRIES:
        return
    msg = "Crew %s não iniciou o 1º turno depois do boot (digitado às %s, sem sinal há %d min). Abra: tmux -L %s attach -t %s" % (
        t["name"], time.strftime("%H:%M", time.localtime(rec["sent_at"])), (now - rec["sent_at"]) // 60, c.cfg.tmux[-1], t["name"])
    rc, _, _ = c.io.run([c.cfg.notify, "-p", "4", "-t", "Crew parada pós-boot", msg], c.left(30), {"NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"})
    rec["notify_tries"] = rec.get("notify_tries", 0) + 1
    rec["notified"] = rc in NOTIFY_OK
    c.log("ALARM %s: %s" % ("sent" if rec["notified"] else "NOTIFY-FAILED (notify rc=%s, try %d of %d)" % (rc, rec["notify_tries"], NOTIFY_TRIES), msg))


def retry(c, t, rec, now, why, pane):
    """ONE more try at the typing, only where it is safe: an idle empty pane gets the line again; OUR line sitting in the input box gets the Enter alone; anything else (a person's draft, a dialog, an unreadable pane) is left alone."""
    rec["retried"] = True
    state, text = pane if pane else (None, "")
    if pane is None:
        state, _, text = peek(c.io, c.cfg, t["name"], c.left(c.cfg.sys_t))
    draft = draft_of(text) if text else None
    if state == "idle":
        stage, err = type_line(c.io, c.cfg, t["name"], compose(rec.get("ids")), c.left(c.cfg.sys_t))
        rec["via"], rec["typed_at"] = "tmux+retry", c.io.now()
        c.log("RETRY %s (%s): %s; the line typed again (%s)" % (t["bead"], t["name"], why, stage if stage == "done" else err))
    elif state == "busy" and draft and draft.startswith(TAG):
        ok, err = press_enter(c.io, c.cfg, t["name"], c.left(c.cfg.sys_t))
        rec["via"], rec["typed_at"] = "tmux+enter", c.io.now()
        c.log("RETRY %s (%s): %s; our line was still in the input box, Enter pressed (%s)" % (t["bead"], t["name"], why, "ok" if ok else err))
    else:
        rec["typed_at"] = now
        c.log("RETRY-SKIPPED %s (%s): %s; the pane is not safe to type into (%s)" % (t["bead"], t["name"], why, "no pane read" if state is None else "pane: %s" % state))


def follow_up(c, t, m, rec, now, counts):
    """a line was typed for this very start: confirm it, retry once, or give up loudly."""
    if rec["phase"] == "sent":
        yes, how, pane = proof(c, t, m["entry"], rec)
        if yes:
            rec.update(phase="confirmed", how=how, confirmed_at=now)
            counts["confirmed"] += 1
            c.log("CONFIRMED %s (%s): a turn started %ds after the typing (%s)" % (t["bead"], t["name"], now - rec["sent_at"], how))
            c.log.record(result_record(t, rec, "confirmed"))
            return
        if not rec.get("retried") and now - rec["sent_at"] >= c.cfg.retry_s:
            retry(c, t, rec, now, how, pane)
            counts["pending"] += 1
            return
        if rec.get("retried") and now - rec["typed_at"] >= c.cfg.give_up_s:
            rec.update(phase="gave-up", gave_up_at=now)
            c.log("ERROR UNCONFIRMED %s (%s): no turn started %ds after the typing, not after the retry either (%s)" % (t["bead"], t["name"], now - rec["sent_at"], how))
            c.log.record(result_record(t, rec, "unconfirmed"))
        else:
            counts["pending"] += 1
            return
    if rec["phase"] == "gave-up":
        counts["unconfirmed"] += 1  # a gauge, not an event: every pass counts the sessions that still have no proof
        notify_gave_up(c, t, rec, now)


def first_turn(c, t, m, counts):
    """-> the state record of this start (None = nothing typed). The bead lookups come first and the pane is read AGAIN right before the typing: the lookups take seconds, and a person may have started typing meanwhile."""
    e = m["entry"]
    ids, unread = ids_for(c, t)
    seen_ids = "%s%s" % (", ".join(ids) or "none found", " (could not read: %s)" % ", ".join(unread) if unread else "")
    st, why, _ = peek(c.io, c.cfg, t["name"], c.left(c.cfg.sys_t))
    if st != "idle":
        kind = "unknown" if st == "unknown" else "wait"
        counts[kind] += 1
        c.note(t["name"], "%s %s (%s): the pane changed before the typing: %s" % (kind.upper(), t["bead"], t["name"], why))
        return None
    if c.dry:
        c.log("WOULD type %s (%s), beads in progress: %s: %s" % (t["bead"], t["name"], seen_ids, compose(ids)))
        counts["typed"] += 1
        return None
    path = find_transcript(c.cfg.claude, e["sessionId"])
    # vazio (sem transcript: conversa nova) → offset 0; falhou (stat) → offset 0: a prova lê do começo e só a marca da NOSSA linha conta
    try:
        offset = os.stat(path).st_size if path else 0
    except OSError:
        offset = 0
    sent_at = c.io.now()
    stage, err = type_line(c.io, c.cfg, t["name"], compose(ids), c.left(c.cfg.sys_t))
    if stage == "text-failed":
        counts["unknown"] += 1
        c.log("TYPE-FAILED %s (%s): %s" % (t["bead"], t["name"], err))
        return None
    counts["typed"] += 1
    c.log("TYPED %s (%s): the first turn, beads in progress: %s%s" % (t["bead"], t["name"], seen_ids, "" if stage == "done" else " (%s: the line waits in the input box for the retry)" % err))
    return {"pid": e["pid"], "start": m["start"], "phase": "sent", "sid": e["sessionId"], "sent_at": sent_at, "typed_at": c.io.now(), "retried": False, "via": "tmux", "offset": offset, "path": path, "ids": ids}


def step_target(c, t, registry, state, counts):
    """one target of one pass: match its claude, follow up a typed line of this start, or judge and type the first turn."""
    io, cfg = c.io, c.cfg
    st, m = match_entry(io, t, registry, c.left(cfg.sys_t))
    if st != "ok":
        counts[st] += 1
        c.note(t["name"], "%s %s (%s): %s" % (st.upper(), t["bead"], t["name"], m))
        return
    rec = state.get(t["name"])
    if rec is not None and same_start(rec, m["entry"]["pid"], m["start"]):
        if c.dry:
            c.log("DRY %s (%s): the record of this start says %s" % (t["bead"], t["name"], rec.get("phase")))
        else:
            follow_up(c, t, m, rec, io.now(), counts)
        return
    verdict, why, _ = assess(io, cfg, t, m, io.now(), c.left(cfg.sys_t))
    if verdict != "ready":
        counts[verdict] += 1
        c.note(t["name"], "%s %s (%s): %s" % (verdict.upper(), t["bead"], t["name"], why))
        return
    path = find_transcript(cfg.claude, m["entry"]["sessionId"])
    seen = tail_records(path) if path else []
    if seen and has_tag(seen, m["start"] - START_SLACK_S):  # the record is lost but the transcript knows: this start already got its line
        state[t["name"]] = {"pid": m["entry"]["pid"], "start": m["start"], "phase": "confirmed", "sid": m["entry"]["sessionId"], "sent_at": io.now(), "typed_at": io.now(), "how": "transcript (found without a record)", "via": "earlier pass", "ids": []}
        counts["confirmed"] += 1
        c.log("CONFIRMED %s (%s): the transcript already carries our line since this start (the record was lost)" % (t["bead"], t["name"]))
        return
    rec = first_turn(c, t, m, counts)
    if rec is not None:
        state[t["name"]] = rec
        c.notes.pop(t["name"], None)


def run_pass(cfg, io, dry=False):
    """-> (exit code, counts). 0 evaluated · 3 could not evaluate (registry or roster unreadable: nothing typed)."""
    counts = dict.fromkeys(COUNTS, 0)
    c = Ctx(cfg, io, dry, {})
    registry, bad = load_registry(cfg.home)
    if registry is None:
        c.log("ERROR: cannot evaluate, nothing typed: ~/.claude/sessions unreadable")
        return 3, counts
    state, c.notes = load_state(cfg.state)
    if not has_pending(state, io.now()) and not any(e.get("kind") in (None, "interactive") and maybe_fresh(e, io.now(), cfg.window_s) for e in registry):
        return 0, counts  # steady state (every crew is days old): no bd, gc, ps or tmux call and no log line
    if bad:  # a file that cannot be read is no claude we know of: said once, so a session that looks absent has a reason
        c.note("_registry", "WARN: %d file(s) in ~/.claude/sessions could not be read or are not a session entry: a session whose file is among them looks absent" % bad)
    else:
        c.notes.pop("_registry", None)
    crews, bad_crews = crew_templates(cfg.agents)
    if crews is None:
        c.note("_agents", "WARN: agents/ unreadable: only the Mayor is a target")
    elif bad_crews:
        c.note("_agents", "WARN: agent.toml unreadable for %s: not a target this pass (a crew whose file cannot be read is not known to be one)" % ", ".join(bad_crews))
    else:
        c.notes.pop("_agents", None)
    roster = None
    for src in (load_roster_bd, load_roster):
        roster = src(io, cfg, c.left(cfg.bd_t if src is load_roster_bd else cfg.gc_t))
        if roster is not None:
            break
    if roster is None:
        c.log("ERROR: cannot evaluate, nothing typed: the session beads (bd query) and gc session list are both unreadable")
        return 3, counts
    targets = pick_targets(roster, crews)
    counts["targets"] = len(targets)
    before = json.dumps([state, c.notes], sort_keys=True)
    for t in targets:
        if io.now() >= c.end:
            c.log("WARN: time budget of the pass spent before %s (%s): the next pass resumes" % (t["bead"], t["name"]))
            break
        try:
            step_target(c, t, registry, state, counts)
        except Exception as ex:  # a surprise in one target must not blind the others, nor hide that the target was not looked at
            counts["unknown"] += 1
            c.log("ERROR %s (%s): unexpected %s: %s" % (t["bead"], t["name"], type(ex).__name__, ex))
        save_state_safe(c, state)
    for name in [n for n, r in state.items() if io.now() - r["sent_at"] > PRUNE_AFTER_S]:
        del state[name]  # forgotten by age
    names = {t["name"] for t in targets}
    for key in [k for k in c.notes if k not in names and not k.startswith("_")]:
        del c.notes[key]
    if json.dumps([state, c.notes], sort_keys=True) != before:
        save_state_safe(c, state)
    return 0, counts


def save_state_safe(c, state):
    if c.dry:
        return
    try:
        save_state(c.cfg.state, state, c.notes)
    except OSError as ex:
        c.log("WARN: cannot save %s: %s: the next pass may type once more into a start it already served (harmless)" % (c.cfg.state, ex))


def is_off(cfg):
    # vazio (sem o arquivo .off) → ligado; falhou/ilegível (stat com erro que não é «não existe»: permissão, laço de symlink, EIO) → desligado: os.path.exists leria isso como «ausente» e digitaria
    if not cfg.enabled:
        return True
    try:
        os.stat(cfg.off_file)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def main(argv=None, env=None, io=None):
    argv = sys.argv[1:] if argv is None else argv
    if not set(argv) <= {"--dry-run"} or len(set(argv)) != len(argv):
        sys.stderr.write("usage: boot-first-turn.py [--dry-run]\n")
        return 2
    dry = "--dry-run" in argv
    cfg, io = Cfg(os.environ if env is None else env), io or RealIO()
    tag = "boot-first-turn:"
    if is_off(cfg):
        print("%s desligado (BFT_ENABLED=0 ou .gc/boot-first-turn.off)" % tag)
        return 0
    try:
        fh = open(cfg.lock, "a")
    except OSError as ex:
        print("%s NÃO consegui abrir a trava %s: %s" % (tag, cfg.lock, ex))
        return 3
    try:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("%s outra instância em curso" % tag)
            return 4
        except OSError as ex:
            print("%s NÃO consegui travar %s: %s" % (tag, cfg.lock, ex))
            return 3
        code, c = run_pass(cfg, io, dry)
    finally:
        fh.close()
    if code != 0:
        print("%s NÃO consegui avaliar (ver %s)" % (tag, cfg.log))
        return code
    print("%s alvos=%d digitou=%d confirmou=%d pendente=%d sem-prova=%d espera=%d tarde=%d nao-sei=%d ausente=%d%s" % (
        tag, c["targets"], c["typed"], c["confirmed"], c["pending"], c["unconfirmed"], c["wait"], c["late"], c["unknown"], c["absent"], " (dry-run)" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
