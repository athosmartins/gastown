#!/usr/bin/env python3
"""nightly-session-compact.py (ga-esorlre.4) — at ~23:00, compact (never /clear) the big conversation of every named crew and of the Mayor, while it is IDLE.

WHY  Athos 12/11: a crew resumes after the 23:40 reboot in its own conversation; if that conversation is huge the resume costs a fortune. So at night every
  big conversation is compacted, finished or not, never cleared. This script edits nothing: it types `/compact` and checks the transcript.
WHAT  The `gc order` fires at 02:00 UTC (= 23:00 local; order crons are UTC). Targets: gastown.mayor + the named crews of agents/*/agent.toml (the Layer-1 rule
  of crew-idle-check.sh) read from `gc session list --json`. Each target maps to its live Claude process in ~/.claude/sessions/<pid>.json (tmux session
  name, else the crew's work_dir) and to ~/.claude/projects/*/<sessionId>.jsonl: context = the last assistant usage (input + cache creation + cache read),
  or postTokens of a newer compact_boundary. Context >= NSC_MIN_TOKENS (250000) AND idle => /compact. Nothing starts after NSC_WINDOW_END (23:25 local), at
  most NSC_MAX_PARALLEL (3) run at once, and every outcome (tokens before/after) is one line of .gc/logs/nightly-session-compact.jsonl.
THREE STATES  Idle needs ALL of: registry status idle for >= NSC_IDLE_MIN_S (no status field: transcript quiet for twice that); the last turn finished
  (assistant end_turn, then turn_duration) and quiet; no background task opened since the process started (transcript pairing); and a pane
  (`gc session peek`) that is a Claude prompt with nothing running, no dialog, an EMPTY input box (a human draft) and no shell/agent/monitor in the footer.
  Busy is retried on the next pass; unreadable or ambiguous is "unknown": NOT compacted, with the reason in the log. Failure never looks like empty.
DELIVERY  `gc session nudge <name> /compact --delivery immediate --json`. Proof is in the transcript: a compact_boundary after the offset taken at send
  time = compacted (preTokens/postTokens); a local_command "Error during compaction" = failed (a usage limit repeats: no retry). No sign of life for
  NSC_RETRY_AFTER_S (90, or 20 if the nudge did not type): a working pane counts as life; an idle pane with an empty input box gets ONE retry typed by tmux.
KNOBS  NSC_ENABLED=0 or $CITY/.gc/nightly-session-compact.off · NSC_DRY_RUN=1 / --dry-run · --force (outside the window) · NSC_MIN_TOKENS · NSC_IDLE_MIN_S ·
  NSC_WINDOW_START/END (HH:MM local) · NSC_MAX_PARALLEL · NSC_CONFIRM_TIMEOUT_S · NSC_RETRY_AFTER_S · NSC_POLL_S · NSC_PASS_INTERVAL_S · NSC_GRACE_S ·
  NSC_GC / NSC_TMUX / NSC_TMUX_SOCKET (gascity) · NSC_HOME · GC_CITY_PATH.  EXIT 0 ran · 2 usage · 3 could not evaluate (roster never readable, lock).
"""
import argparse
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
TERMINAL = ("completed", "failed", "killed", "stopped", "cancelled", "canceled", "timeout", "error")
DUR = r"([0-9]+h[ \t]+)?([0-9]+m[ \t]+)?[0-9]+s"
GLYPH = r"(✻|✽|✳|✶|✢|✺|✹|·|\*)"
DIALOG_RE = re.compile(r"Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel")
BUSY_RE = re.compile(r"(…|\.\.\.)[^(]*\(" + DUR + "|esc to interrupt")
SPIN_RE = re.compile(r"^\s*" + GLYPH + r"\s+\S+(…|\.\.\.)", re.M)
FOOT_RE = re.compile(r"\b\d+ (?:shells?|bash(?:es)?|(?:local |remote |background )?agents?|tasks?|monitors?)\b")
START_RE = re.compile(r"\s*(?:Command running in background with ID: |Monitor started \(task )(\w+)")
DONE_RE, STATUS_RE = re.compile(r"<task-id>(\w+)</task-id>"), re.compile(r"<status>(\w+)</status>")
ACTIVE_TYPES = ("user", "assistant", "system", "attachment")

def num(v, default):
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return default
    return n if n > 0 else default

def hhmm(v, default):
    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", str(v or "").strip())
    return (int(m.group(1)), int(m.group(2))) if m else default

class Cfg:
    def __init__(self, env):
        g = env.get
        self.city = g("GC_CITY_PATH") or CITY_DEFAULT
        self.home = g("NSC_HOME") or os.path.expanduser("~")
        self.gc = [g("NSC_GC") or g("GC_BIN") or "gc"] + (["--city", self.city] if g("NSC_GC_CITY", "1") != "0" else [])
        self.tmux, self.socket = g("NSC_TMUX") or "tmux", g("NSC_TMUX_SOCKET") or "gascity"
        self.min_tokens, self.idle_s = num(g("NSC_MIN_TOKENS"), 250000), num(g("NSC_IDLE_MIN_S"), 300)
        self.win_start, self.win_end = hhmm(g("NSC_WINDOW_START"), (22, 30)), hhmm(g("NSC_WINDOW_END"), (23, 25))
        self.max_parallel, self.confirm_s = num(g("NSC_MAX_PARALLEL"), 3), num(g("NSC_CONFIRM_TIMEOUT_S"), 900)
        self.retry_s, self.poll_s, self.pass_s = num(g("NSC_RETRY_AFTER_S"), 90), num(g("NSC_POLL_S"), 10), num(g("NSC_PASS_INTERVAL_S"), 120)
        self.grace_s, self.gc_timeout = num(g("NSC_GRACE_S"), 600), num(g("NSC_GC_TIMEOUT_S"), 120)
        self.enabled, self.dry = g("NSC_ENABLED", "1") != "0", g("NSC_DRY_RUN") == "1"

class RealIO:
    now, sleep = staticmethod(time.time), staticmethod(time.sleep)

    def run(self, argv, timeout):
        """(rc, stdout); rc None = could not start or timed out: never an empty answer."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout)
        except (OSError, subprocess.SubprocessError):
            return None, ""
        return p.returncode, p.stdout

class Log:
    def __init__(self, cfg):
        self.path, self.jsonl = (os.path.join(cfg.city, ".gc", "logs", "nightly-session-compact." + x) for x in ("log", "jsonl"))

    def _append(self, path, line):
        # falhou (diretório ausente, disco cheio) → aviso no stderr e segue: o registro do order não some, e o arquivo não é condição para compactar
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError as ex:
            sys.stderr.write("WARN: cannot append to %s: %s\n" % (path, ex))

    def __call__(self, msg):
        line = "[%s] %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
        print(line, flush=True)
        self._append(self.path, line)

    def record(self, rec):
        rec["ts"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        self._append(self.jsonl, json.dumps(rec, ensure_ascii=False, sort_keys=True))

def day_epoch(now, hm):
    return datetime.datetime.fromtimestamp(now).replace(hour=hm[0], minute=hm[1], second=0, microsecond=0).timestamp()

def crew_templates(agents_dir):
    """template -> work_dir of every named crew (work_dir .../crew/<slug>, slug != worker, max_active_sessions <= 1); None = the dir could not be read."""
    # vazio (nenhum crew) → {}: só o Mayor é alvo; falhou/ilegível (diretório ausente) → None: sem a lista de crews não se compacta crew nenhuma
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
        wd, mx = re.search(r'^work_dir\s*=\s*"([^"]*)"', txt, re.M), re.search(r"^max_active_sessions\s*=\s*(\d+)", txt, re.M)
        slug = re.search(r"/crew/([^/]+)$", wd.group(1)) if wd else None
        if slug and slug.group(1) != "worker" and not (mx and int(mx.group(1)) > 1):
            out[n] = wd.group(1)
    return out

def load_roster(io, cfg):
    # vazio (sessions: []) → [] sem alvos; falhou/ilegível (rc≠0, estouro, JSON ruim, sem "sessions" lista) → None: nada é compactado neste passe
    rc, out = io.run(cfg.gc + ["session", "list", "--json"], cfg.gc_timeout)
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
        tpl = s.get("template") or ""
        if tpl == "gastown.mayor" or tpl in (crews or {}):
            ids = [x for x in (s.get("session_name"), s.get("name"), s.get("alias")) if isinstance(x, str) and x]
            if ids:
                out.append({"name": s.get("name") or ids[0], "template": tpl, "ids": ids, "work_dir": (crews or {}).get(tpl)})
    return out

def load_registry(home):
    """(entries, unreadable_count); entries None = the registry dir could not be read."""
    # vazio (nenhum .json) → ([], 0); falhou (diretório ausente) → (None, 0): sem registro não há prova de nada; arquivo ruim → contado, nunca vira entrada
    d = os.path.join(home, ".claude", "sessions")
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return None, 0
    out, bad = [], 0
    for n in names:
        try:
            with open(os.path.join(d, n), encoding="utf-8") as fh:
                e = json.load(fh)
        except (OSError, ValueError):
            bad += 1
            continue
        if isinstance(e, dict) and isinstance(e.get("sessionId"), str) and isinstance(e.get("pid"), int):
            e["_file"] = os.path.join(d, n)
            out.append(e)
        else:
            bad += 1
    return out, bad

def tmux_name(e):
    t = e.get("tmux")
    return t.split(":", 1)[0] if isinstance(t, str) and ":" in t else None

def pid_alive(io, pid):
    """True / False / None (cannot tell): the pid exists AND its command names claude (a recycled pid is someone else's)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # the pid exists and is another user's: the ps check below decides, as for any live pid
    except OSError:
        return None
    # vazio/rc 1 (ps não acha o pid) → False; falhou (ps sem rodar ou estouro) → None: não se sabe
    rc, out = io.run(["ps", "-o", "command=", "-p", str(pid)], 15)
    return None if rc is None else (rc == 0 and "claude" in out.lower())

def match_entry(io, t, registry):
    """(entry, why): the ONE live interactive Claude process of the target (tmux session name, else the crew's work_dir)."""
    cand = [e for e in registry if e.get("kind") == "interactive" and (
        tmux_name(e) in t["ids"] or (tmux_name(e) is None and t["work_dir"] and e.get("cwd") == t["work_dir"]))]
    alive = []
    for e in cand:
        a = pid_alive(io, e["pid"])
        if a is None:
            return None, "cannot tell whether pid %s is alive" % e["pid"]
        if a:
            alive.append(e)
    if len(alive) != 1:
        seen = sorted({tmux_name(x) for x in registry if tmux_name(x)})[:8]
        return None, "%d live claude processes match %s (%d registry files by name; registry tmux sessions: %s)" % (len(alive), t["ids"], len(cand), seen)
    e = alive[0]
    if t["work_dir"] and e.get("cwd") and os.path.realpath(e["cwd"]) != os.path.realpath(t["work_dir"]):
        return None, "registry cwd %s is not the crew's work_dir %s" % (e["cwd"], t["work_dir"])
    return e, ""

def find_transcript(home, sid):
    # vazio (nenhum arquivo) / id estranho → None: sem transcript não se sabe o que a conversa é; mais de um (conversa retomada) → o de mtime mais novo
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", sid):
        return None
    hits = glob.glob(os.path.join(home, ".claude", "projects", "*", sid + ".jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None

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

def read_tail(path, nbytes):
    """(records, size, mtime) of the last nbytes (a cut first line does not parse and is ignored); None when the file cannot be read."""
    # vazio (nenhum registro no rabo) → ([], size, mtime); falhou (OSError) → None; linha cortada/corrompida → ignorada
    try:
        st = os.stat(path)
        with open(path, "rb") as fh:
            off = max(0, st.st_size - nbytes)
            fh.seek(off)
            data = fh.read()
    except OSError:
        return None
    return parse_lines(data), st.st_size, st.st_mtime

def text_of(r):
    c = (r.get("message") or {}).get("content")
    if isinstance(c, list):
        c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return c if isinstance(c, str) else ""

def context_state(recs):
    """('tokens', n) | ('boundary', postTokens|None) from the NEWEST assistant usage or compact boundary; None = neither is in the records."""
    for r in reversed(recs):
        if r.get("type") == "system" and r.get("subtype") == "compact_boundary":
            cm = r.get("compactMetadata")
            post = cm.get("postTokens") if isinstance(cm, dict) else None
            return "boundary", post if isinstance(post, int) else None
        m = r.get("message") if r.get("type") == "assistant" and not r.get("isSidechain") else None
        u = m.get("usage") if isinstance(m, dict) and m.get("model") != "<synthetic>" else None
        if isinstance(u, dict):
            n = sum(u.get(k) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens") if isinstance(u.get(k), int))
            if n > 0:
                return "tokens", n
    return None

def turn_state(recs, age, quiet):
    """('idle', '') | ('busy'|'unknown', why): the last real turn is finished (assistant end_turn, then turn_duration)."""
    real = [i for i, r in enumerate(recs) if r.get("type") in ("user", "assistant") and not r.get("isSidechain") and not r.get("isMeta")
            and not (r["type"] == "user" and text_of(r).lstrip().startswith(("<local-command", "<command-name>", "/")))]
    if not real:
        return "unknown", "no user/assistant record in the tail"
    r = recs[real[-1]]
    if r["type"] == "user":
        return "busy", "a prompt or tool_result after the last assistant message waits for the model"
    sr = (r.get("message") or {}).get("stop_reason")
    if sr != "end_turn":
        return "busy", "the last assistant record has stop_reason=%s" % sr
    if any(x.get("type") == "system" and x.get("subtype") == "turn_duration" for x in recs[real[-1] + 1:]) or age >= 2 * quiet:
        return "idle", ""
    return "busy", "end_turn written but not turn_duration (stop hooks may still run)"

def open_background(path, since_ms):
    """Task ids started after the process start and never reported finished; None = the file could not be read."""
    # vazio (nenhuma tarefa) → []; falhou (OSError) → None: não se sabe se há trabalho em segundo plano; linha ilegível → ignorada
    since = (since_ms or 0) / 1000.0
    started, done = {}, set()
    try:
        with open(path, "rb") as fh:
            for ln in fh:
                if b"ackground" not in ln and b"Monitor started" not in ln and b"<task-notification>" not in ln:
                    continue
                for r in parse_lines(ln):
                    try:
                        ts = datetime.datetime.strptime(str(r.get("timestamp") or "")[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
                    except ValueError:
                        ts = since
                    if ts < since:
                        continue
                    c = (r.get("message") or {}).get("content")
                    for b in c if isinstance(c, list) else []:
                        t = b.get("content") if isinstance(b, dict) and b.get("type") == "tool_result" else None
                        t = " ".join(x.get("text", "") for x in t if isinstance(x, dict)) if isinstance(t, list) else t
                        m = START_RE.match(t) if isinstance(t, str) else None
                        if m:
                            started[m.group(1)] = ts
                    blob = json.dumps(r.get("attachment") or r.get("message") or {}, ensure_ascii=False)
                    for n in re.finditer(r"<task-notification>(.*?)</task-notification>", blob, re.S):
                        i, s = DONE_RE.search(n.group(1)), STATUS_RE.search(n.group(1))
                        if i and s and s.group(1) in TERMINAL:
                            done.add(i.group(1))
    except OSError:
        return None
    return sorted(set(started) - done)

def read_pane(text):
    """(state, why): idle = a Claude prompt with nothing running, no dialog, an EMPTY input box and no background work in the footer.
    Other states: working (a turn or a compaction runs) · busy (a draft in the input box, background work) · dialog · unknown."""
    lines = [x.rstrip() for x in text.splitlines() if x.strip()]
    if DIALOG_RE.search("\n".join(lines[-12:])):
        return "dialog", "a dialog waits for a key"
    if BUSY_RE.search(text):
        return "working", "a turn is running"
    if SPIN_RE.search(text):
        return "unknown", "a spinner whose timer cannot be read"
    prompt = next((x for x in reversed(lines) if x.lstrip().startswith("❯")), None)
    if prompt is None:
        return "unknown", "no Claude Code prompt in view"
    if prompt.lstrip()[1:].strip():
        return "busy", "the input box holds text: %r" % prompt.lstrip()[1:].strip()[:40]
    foot = next((x for x in lines[-3:] if "·" in x and FOOT_RE.search(x)), None)
    if foot:
        return "busy", "background work in the footer: %s" % foot.strip()[:80]
    return "idle", ""

def peek(io, cfg, name):
    # vazio (peek sem texto) / falhou (rc≠0, estouro) → "unknown": ninguém digita num pane que não se leu
    rc, out = io.run(cfg.gc + ["session", "peek", name, "--lines", "40"], 60)
    return read_pane(out) if rc == 0 and out.strip() else ("unknown", "the pane could not be read (rc %s)" % rc)

def assess(io, cfg, t, registry):
    """(verdict, why, info); verdict = ready | small | compacted | busy | unknown. Cheap checks first; the pane is the last."""
    e, why = match_entry(io, t, registry)
    if e is None:
        return "unknown", why, {}
    info = {"pid": e["pid"], "session_id": e["sessionId"], "entry": e}
    quiet, status, sa = cfg.idle_s, e.get("status"), e.get("statusUpdatedAt")
    if status is None:
        quiet *= 2
    elif status != "idle":
        return "busy", "registry status=%s" % status, info
    elif not isinstance(sa, (int, float)):
        return "unknown", "registry status idle without statusUpdatedAt", info
    elif io.now() - sa / 1000.0 < cfg.idle_s:
        return "busy", "registry idle for only %ds" % (io.now() - sa / 1000.0), info
    path = find_transcript(cfg.home, e["sessionId"])
    if path is None:
        return "unknown", "no single transcript for session %s" % e["sessionId"], info
    info["path"] = path
    tail = read_tail(path, 8 << 20)
    ctx = context_state(tail[0]) if tail else None
    if tail is None or ctx is None:
        return "unknown", "transcript unreadable or no assistant usage / compact boundary in its last 8 MB", info
    recs, _, mtime = tail
    n = info["tokens"] = ctx[1]
    if ctx[0] == "boundary" and n is None:
        return "compacted", "a compact boundary is newer than the last assistant message", info
    if n < cfg.min_tokens:
        return "small", "%d < %d tokens" % (n, cfg.min_tokens), info
    age = io.now() - mtime
    if age < quiet:
        return "busy", "transcript written %ds ago" % age, info
    state, why = turn_state(recs, age, quiet)
    if state != "idle":
        return state, "transcript: " + why, info
    bg = open_background(path, e.get("startedAt"))
    if bg is None or bg:
        return ("unknown", "background tasks could not be read", info) if bg is None else ("busy", "background task(s) open: %s" % ",".join(bg[:3]), info)
    state, why = peek(io, cfg, t["name"])
    return ("ready", "", info) if state == "idle" else ("unknown" if state == "unknown" else "busy", "pane: " + why, info)

def nudge(io, cfg, name):
    """(outcome, detail) of `gc session nudge`: delivered | queued | unreadable | failed. Only `delivered` is known to be typed; the rest is watched for a sign of life too."""
    # vazio (rc 0 sem JSON legível) → "unreadable"; falhou (rc≠0, estouro) → "failed"; "queued" = a fila, não digitado
    rc, out = io.run(cfg.gc + ["session", "nudge", name, "/compact", "--delivery", "immediate", "--json"], cfg.gc_timeout)
    if rc != 0:
        return "failed", "rc %s" % rc
    try:
        j = json.loads(out)
        oc = j.get("outcome") if j.get("ok") is True else None
    except (ValueError, AttributeError):
        oc = None
    return (oc if oc in ("delivered", "queued") else "unreadable"), "outcome=%r" % oc

def read_new(f):
    """Records appended since f['offset'] (complete lines only); the offset advances. Unreadable → [] and nothing advances."""
    # vazio (nada novo) → []; falhou (OSError) → []: o prazo do alvo decide, nunca "compactou"
    try:
        with open(f["path"], "rb") as fh:
            fh.seek(f["offset"])
            data = fh.read()
    except OSError:
        return []
    cut = data.rfind(b"\n") + 1
    f["offset"] += cut
    return parse_lines(data[:cut])

def poll(io, cfg, f, end):
    """None (keep watching) | a result dict."""
    for r in read_new(f):
        t, s = r.get("type"), r.get("subtype")
        if t == "system" and s == "compact_boundary":
            cm = r.get("compactMetadata") if isinstance(r.get("compactMetadata"), dict) else {}
            return {"result": "compacted", "tokens_before": cm.get("preTokens", f["tokens"]), "tokens_after": cm.get("postTokens"), "duration_ms": cm.get("durationMs")}
        if t == "system" and s == "local_command" and "Error during compaction" in str(r.get("content")):
            msg = re.sub(r"<[^>]+>", "", str(r.get("content"))).strip()[:200]
            return {"result": "failed", "reason": msg}
        if t in ACTIVE_TYPES:
            f["activity"] = True
    # vazio (arquivo do registro sumiu) → sem sinal; falhou/ilegível (load_registry devolve None) → sem sinal: o prazo decide, nunca "compactou"
    cur, _ = load_registry(cfg.home)
    e = next((x for x in cur or [] if x["_file"] == f["entry"]["_file"]), None)
    if e and (e.get("status") != "idle" or e.get("statusUpdatedAt") != f["entry"].get("statusUpdatedAt")):
        f["activity"] = True
    now = io.now()
    if not f["activity"] and not f["retried"] and now >= f["retry_at"]:
        f["retried"] = True
        retry_tmux(io, cfg, f, now)
    if not f["activity"] and f["retried"] and now >= (f["typed_at"] or f["retry_at"]) + (120 if f["typed_at"] else 60):
        return {"result": "unconfirmed", "reason": "no sign of life (%s)" % "; ".join(f["notes"])}
    if now >= min(f["deadline"], end):
        return {"result": "unconfirmed", "reason": "no compact_boundary before the deadline (%s)" % ("activity seen" if f["activity"] else "no sign of life")}
    return None

def retry_tmux(io, cfg, f, now):
    """ONE look at a session that shows no sign of life: a working pane counts as life; an idle pane with an EMPTY input box gets /compact typed by tmux."""
    state, why = peek(io, cfg, f["t"]["name"])
    if state == "working":
        f["activity"] = True
        f["notes"].append("pane shows work: %s" % why)
        return
    if state != "idle":
        f["notes"].append("tmux retry skipped: pane %s (%s)" % (state, why))
        return
    sess = tmux_name(f["entry"]) or f["t"]["ids"][0]
    for keys in (["-l", "/compact"], ["Enter"]):
        rc, _ = io.run([cfg.tmux, "-L", cfg.socket, "send-keys", "-t", "=%s:" % sess] + keys, 15)
        if rc != 0:
            f["notes"].append("tmux retry failed: send-keys %s rc %s" % (keys[-1], rc))
            return
        io.sleep(1.0)
    f["via"], f["typed_at"] = "nudge+tmux", io.now()
    f["notes"].append("tmux retry typed /compact")

def start(io, cfg, t, info):
    """Send /compact; -> an in-flight record, or a result dict when nothing can be watched."""
    # falhou (stat) → o alvo não é compactado: sem o ponto de partida não há como provar o efeito
    try:
        off = os.path.getsize(info["path"])
    except OSError:
        return {"result": "unknown", "reason": "transcript vanished before the send"}
    oc, detail = nudge(io, cfg, t["name"])
    now = io.now()
    return {"t": t, "path": info["path"], "offset": off, "sent": now, "deadline": now + cfg.confirm_s, "tokens": info["tokens"], "entry": info["entry"],
            "activity": False, "retried": False, "typed_at": None, "retry_at": now + (cfg.retry_s if oc == "delivered" else 20), "via": "nudge",
            "notes": ["nudge %s %s" % (oc, detail)]}

def run(cfg, io, log, force=False):
    now = io.now()
    if not cfg.enabled or os.path.exists(os.path.join(cfg.city, ".gc", "nightly-session-compact.off")):
        log("off (NSC_ENABLED=0 or the .off file): nothing done")
        return 0
    first, end = day_epoch(now, cfg.win_start), day_epoch(now, cfg.win_end)
    if force:
        first, end = now, now + 1200
    if not first <= now <= end:
        log("outside the window %02d:%02d-%02d:%02d local: nothing done (--force overrides)" % (cfg.win_start + cfg.win_end))
        return 0
    try:
        os.makedirs(os.path.join(cfg.city, ".gc", "state"), exist_ok=True)
        lock = os.open(os.path.join(cfg.city, ".gc", "state", "nightly-session-compact.lock"), os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another run holds the lock: in flight, nothing done")
        return 0
    except OSError as ex:
        log("ERROR: cannot take the instance lock (%s): nothing done" % ex)
        return 3
    log("start: window ends %s, min_tokens=%d idle>=%ds parallel<=%d%s" % (time.strftime("%H:%M", time.localtime(end)), cfg.min_tokens, cfg.idle_s, cfg.max_parallel, " DRY-RUN" if cfg.dry else ""))
    crews = crew_templates(os.path.join(cfg.city, "agents"))
    if crews is None:
        log("WARN: agents/ unreadable: only the Mayor is a target")
    roster, next_pass = None, 0
    settled, inflight, why_not = {}, {}, {}

    def settle(name, rec, line=None):
        rec["target"] = name
        settled[name] = rec
        log(line or "%s: %s (%s)" % (name, rec["result"], rec.get("reason", "")))
        log.record(rec)

    while True:
        now = io.now()
        for name, f in list(inflight.items()):
            res = poll(io, cfg, f, end + cfg.grace_s)
            if res:
                del inflight[name]
                res.update(via=f["via"], notes=f["notes"], tokens_before=res.get("tokens_before", f["tokens"]), seconds=int(now - f["sent"]), session_id=f["entry"]["sessionId"])
                settle(name, res, "%s: %s (%s -> %s tokens) %s" % (name, res["result"], res["tokens_before"], res.get("tokens_after"), res.get("reason", "")))
        if now < end and now >= next_pass and len(inflight) < cfg.max_parallel:
            if roster is None:
                roster = load_roster(io, cfg)
                if roster is None:
                    log("WARN: `gc session list` unreadable this pass: nothing compacted from it")
            registry, bad = load_registry(cfg.home)
            if registry is None or bad:
                log("WARN: ~/.claude/sessions: %s" % ("unreadable: no target can be proven idle" if registry is None else "%d unreadable file(s) ignored" % bad))
            ready = []
            for t in pick_targets(roster or [], crews):
                n = t["name"]
                if n in settled or n in inflight:
                    continue
                verdict, why, info = assess(io, cfg, t, registry) if registry is not None else ("unknown", "the Claude session registry is unreadable", {})
                if verdict in ("small", "compacted"):
                    settle(n, {"session_id": info.get("session_id"), "tokens_before": info.get("tokens"), "result": verdict, "reason": why})
                elif verdict == "ready":
                    ready.append((t, info))
                else:
                    why_not[n] = (verdict, why)
                    log("%s: %s: %s" % (n, verdict, why))
            backlog = False
            for t, info in sorted(ready, key=lambda x: -x[1]["tokens"]):
                n, base = t["name"], {"session_id": info["session_id"], "tokens_before": info["tokens"]}
                if cfg.dry:
                    settle(n, dict(base, result="dry-run", reason="WOULD compact"))
                elif len(inflight) >= cfg.max_parallel:
                    backlog, why_not[n] = True, ("ready", "waited for a free slot until the window ended")
                else:
                    log("%s: idle at %d tokens: sending /compact" % (n, info["tokens"]))
                    f = start(io, cfg, t, info)
                    if "result" in f:
                        settle(n, dict(base, **f))
                    else:
                        inflight[n] = f
            next_pass = now if backlog else now + cfg.pass_s  # a ready target waits for a slot: look again the moment one frees
        pending = [t for t in pick_targets(roster or [], crews) if t["name"] not in settled]
        if not inflight and (now >= end or (roster is not None and not pending)):
            break
        io.sleep(cfg.poll_s)
    if roster is None:
        log("ERROR: `gc session list` was never readable: nothing was evaluated")
        return 3
    for t in pick_targets(roster or [], crews):
        if t["name"] not in settled:
            settle(t["name"], {"result": "skipped", "reason": "%s: %s" % why_not.get(t["name"], ("unknown", "never assessed"))})
    tally = {}
    for r in settled.values():
        tally[r["result"]] = tally.get(r["result"], 0) + 1
    left = ["%s (%s)" % (n, r.get("reason", r["result"])) for n, r in sorted(settled.items()) if r["result"] in ("skipped", "failed", "unconfirmed", "unknown")]
    log("SUMMARY %s%s" % (json.dumps(tally, sort_keys=True), "; NOT compacted: " + "; ".join(left) if left else ""))
    return 0

def main(argv=None, env=None, io=None):
    ap = argparse.ArgumentParser(description="Compact the big idle conversations of the named crews and the Mayor before the nightly reboot (ga-esorlre.4)")
    ap.add_argument("--force", action="store_true", help="run outside the nightly window (a manual run; the window is then 20 min from now)")
    ap.add_argument("--dry-run", action="store_true", help="assess and log, send nothing")
    a = ap.parse_args(argv)
    cfg = Cfg(env if env is not None else os.environ)
    cfg.dry = cfg.dry or a.dry_run
    return run(cfg, io or RealIO(), Log(cfg), force=a.force)

if __name__ == "__main__":
    sys.exit(main())
