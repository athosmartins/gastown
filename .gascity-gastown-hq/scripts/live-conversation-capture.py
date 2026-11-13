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
ARM (ga-esorlre.3, only in --final)  After the capture, each live target is ARMED so the next boot RESUMES that conversation instead of starting a fresh one. Why: at boot the engine finds the session bead `active` with
  no runtime and no deliberate sleep_reason, calls it an unexpected death, wipes session_key and starts `--session-id <new>` (measured 12/11 23:47: Mayor + every crew came back on a new id; internal/session/
  lifecycle_projection.go shouldResetContinuation + cmd/gc/session_reconcile.go healState). The same engine keeps the key when sleep_reason is deliberate (what `gc stop` writes: city-stop). So ONE `bd update`:
  session_key=<live id> (the conversation the Athos uses, not the one the bead minted), sleep_reason=city-stop, session.resume_armed_id/_at, and the stale reset_committed_at dropped (ga-esorlre.3 item 5).
  Guards (refuse = leave the engine default, a fresh start; the reason is logged): wake_mode=fresh in config (the Mayor today: arming would be ignored) · reset/restart pending · quarantined · another sleep_reason ·
  transcript unreadable or without a usage record / last request over LCC_MAX_RESUME_TOKENS (700000: the model's window is >= 1M and crew conversations really reach 300-577k, so the 300k first suggested would refuse
  most crews). A tool call still in flight (transcript ends in a tool_use) is NOT refused: measured 12/11 on this CLI, `claude --resume` of a transcript cut right after a tool_use answers normally (it drops the orphan
  call), and a crew is mid-tool at almost any instant; LCC_REFUSE_DANGLING=1 turns the refusal on. Cannot read the bead / transcript (unknown) = refuse: three states, never "empty == fine".
  AFTER BOOT (normal passes): armed + last_woke_at later than the arming -> session.resume_result=ok (same id) or fresh (other id; the session gets ONE nudge naming the old id); armed and no restart for
  LCC_DISARM_AFTER_S (900) -> sleep_reason=city-stop is removed again (the reboot did not happen). A restart onto another id that was never armed (guard said no, crash) gets the same nudge.
KNOBS  LCC_ENABLED=0 or .gc/live-conversation-capture.off · LCC_HOME · LCC_CLAUDE_DIR · LCC_GC · LCC_BD · LCC_TMUX · LCC_TMUX_SOCKET · LCC_REFRESH_S · LCC_BUDGET_S · LCC_FINAL_BUDGET_S ·
  LCC_LOCK_WAIT_S · LCC_GC_TIMEOUT_S/LCC_BD_TIMEOUT_S/LCC_SYS_TIMEOUT_S · LCC_ARM=0 (capture only) · LCC_MAX_RESUME_TOKENS · LCC_REFUSE_DANGLING · LCC_DISARM_AFTER_S · LCC_ARM_WORKERS.  EXIT 0 evaluated · 2 usage · 3 could not evaluate · 4 another instance runs.
"""
import concurrent.futures
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

CITY_DEFAULT = "/Users/athos/gt/.gascity-gastown-hq"
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
K_ID, K_AT = "session.live_conversation_id", "session.live_conversation_at"
MAYORS = ("gastown.mayor", "mayor")
K_ARM_ID, K_ARM_AT, K_RES, K_RES_AT = "session.resume_armed_id", "session.resume_armed_at", "session.resume_result", "session.resume_result_at"
CITY_STOP = "city-stop"  # the deliberate sleep_reason `gc stop` writes (cmd/gc/cmd_stop.go): shouldResetContinuation keeps session_key for it
TAIL_BYTES = 4 << 20  # how much of a transcript's end the guards read
NUDGE_TRIES = 3  # a nudge that keeps failing is given up after this many tries
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
        self.refuse_dangling = g("LCC_REFUSE_DANGLING", "0") == "1"
        self.arm, self.max_tokens, self.disarm_s, self.workers = g("LCC_ARM", "1") != "0", num(g("LCC_MAX_RESUME_TOKENS"), 700000), num(g("LCC_DISARM_AFTER_S"), 900), num(g("LCC_ARM_WORKERS"), 6)
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


def load_roster_bd(io, cfg, tmo):
    """the same roster from the session beads themselves (`bd query`: ~5 s where `gc session list` takes 22-60 s on a loaded mini); state awake/active = active, as the gc projection does."""
    # vazio (nenhuma bead de sessão aberta) → []: nenhum alvo; falhou/ilegível (rc≠0, estouro, JSON ruim, não-lista) → None
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


def find_transcript(claude, sid):
    """path of <sid>.jsonl or None."""
    # vazio (nenhum arquivo) → None: a conversa ainda não é retomável; diretório sem leitura também dá None (o glob engole o erro): nos dois nada é gravado
    hits = sorted(glob.glob(os.path.join(glob.escape(claude), "projects", "*", sid + ".jsonl")))
    return hits[0] if hits else None


def resolve(io, cfg, tgt, tab, tmo):
    """("live", sessionId) / ("absent", why) / ("unknown", why) for one target."""
    st, pids = pane_pids(io, cfg, tgt["tname"], tmo)
    if st != "ok":
        return st, pids
    by_pid = {}
    for pid in descend(tab, pids):
        if pid not in tab:
            continue
        s, e = read_entry(cfg.claude, pid, tab[pid][1])
        if s == "bad":
            return "unknown", e
        if s == "ok":
            by_pid[pid] = e
    if not by_pid:
        return "absent", "no claude registry entry under the pane"
    # a claude started BY the pane's claude (a `claude -p` helper of a script, seen in thies at 00:01) is not the conversation in the pane: the OUTERMOST claude is (ga-esorlre.3)
    def nested(pid):
        q, d = tab[pid][0], 0
        while q in tab and d < 64:
            if q in by_pid:
                return True
            q, d = tab[q][0], d + 1
        return False
    found = {}
    for pid, e in by_pid.items():
        if not nested(pid):
            found[e["sessionId"]] = e
    if len(found) > 1:
        return "unknown", "%d live conversations in one pane (%s)" % (len(found), " ".join(sorted(found)))
    sid, e = next(iter(found.items()))
    tm = e.get("tmux")
    if isinstance(tm, str) and tm and tm.split(":", 1)[0] != tgt["tname"]:
        return "unknown", "registry says tmux session %s, the target is %s" % (tm.split(":", 1)[0], tgt["tname"])
    if not find_transcript(cfg.claude, sid):
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
    """(ok, why, metadata read back or None): ONE bd update with both keys, then a read-back of the id; only a value read back counts as written.
    The update and the read-back share ONE allowance (`tmo`, already clamped to the pass budget): the read-back gets what the update left of it (floor 1 s), so a slow Dolt cannot stretch a pass by a second full bd timeout."""
    t0 = io.now()
    rc, _, err = io.run(cfg.bd + ["update", bead, "--set-metadata", "%s=%s" % (K_ID, sid), "--set-metadata", "%s=%d" % (K_AT, at)], tmo)
    if rc != 0:
        return False, "bd update rc=%s: %s" % (rc, (err or "").strip()[:100]), None
    # falhou/ilegível (rc≠0, estouro, JSON ruim, sem a chave) → não gravado: o estado não o registra e a próxima rodada escreve de novo
    rc, out, _ = io.run(cfg.bd + ["show", bead, "--json"], max(1, int(tmo - (io.now() - t0))))
    if rc != 0:
        return False, "read-back failed (bd show rc=%s)" % rc, None
    try:
        md = json.loads(out)[0]["metadata"]
        got = md.get(K_ID)
    except (ValueError, LookupError, AttributeError, TypeError):
        return False, "read-back unreadable", None
    return (True, "", md) if got == sid else (False, "read-back says %r, wrote %s" % (got, sid), None)



def read_meta(io, cfg, bead, tmo):
    """the bead's metadata dict, or None."""
    # vazio (bead sem metadata) → {}: não há o que contradizer; falhou/ilegível (rc≠0, estouro, JSON ruim, bead ausente) → None: quem chamou NÃO arma nem conclui nada
    rc, out, _ = io.run(cfg.bd + ["show", bead, "--json"], tmo)
    if rc != 0:
        return None
    try:
        m = json.loads(out)[0].get("metadata")
    except (ValueError, LookupError, AttributeError, TypeError):
        return None
    return {} if m is None else (m if isinstance(m, dict) else None)


def transcript_check(path, max_tokens, refuse_dangling=False):
    """("ok", note) / ("refuse", why) / ("unknown", why): can `claude --resume` of this transcript be trusted? Reads only its last TAIL_BYTES."""
    # vazio (nenhum request assistant na ponta) → unknown, não "ok": sem o tamanho do contexto não sei se cabe; falhou/ilegível (sem leitura) → unknown. Os dois NÃO armam
    try:
        with open(path, "rb") as fh:
            size = fh.seek(0, os.SEEK_END)
            fh.seek(max(0, size - TAIL_BYTES))
            raw = fh.read()
    except OSError as ex:
        return "unknown", "cannot read the transcript: %s" % ex
    lines = raw.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]  # the first line of a tail read is cut in the middle
    uses, results, tokens = set(), set(), None
    for ln in lines:
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        msg = r.get("message") if isinstance(r, dict) else None
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        for b in content if isinstance(content, list) else []:
            if isinstance(b, dict) and b.get("type") == "tool_use" and isinstance(b.get("id"), str):
                uses.add(b["id"])
            elif isinstance(b, dict) and b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str):
                results.add(b["tool_use_id"])
        u = msg.get("usage") if r.get("type") == "assistant" else None
        if isinstance(u, dict) and all(isinstance(u.get(k, 0), int) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")):
            tokens = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
    flying = len(uses - results)
    if flying and refuse_dangling:
        return "refuse", "the transcript ends in a tool_use with no result (%d)" % flying
    if tokens is None:
        return "unknown", "no assistant usage record in the last %d KB: the context size is unknown" % (TAIL_BYTES >> 10)
    if tokens > max_tokens:
        return "refuse", "the last request carried %d tokens (> %d)" % (tokens, max_tokens)
    return "ok", "%d tokens%s" % (tokens, "; %d tool call(s) in flight, claude drops them on resume" % flying if flying else "")


def arm_decision(cfg, meta, sid, tpath):
    """(True, note) / (False, why): may the next boot resume `sid` for the bead whose metadata is `meta`?"""
    sr = str(meta.get("sleep_reason") or "").strip()
    if str(meta.get("wake_mode") or "").strip() == "fresh":
        return False, "wake_mode=fresh in the config: every wake starts a fresh conversation, arming would be ignored (set wake_mode=resume for this agent)"
    if str(meta.get("continuation_reset_pending") or "").strip() == "true" or str(meta.get("restart_requested") or "").strip() == "true":
        return False, "a fresh conversation was already requested (reset/restart pending)"
    if str(meta.get("quarantined_until") or "").strip():
        return False, "the session is quarantined"
    if sr and not (sr == CITY_STOP and meta.get(K_ARM_ID)):
        return False, "sleep_reason=%s is not ours to override" % sr
    st, why = transcript_check(tpath, cfg.max_tokens, cfg.refuse_dangling)
    return (st == "ok", why)


def arm_one(io, cfg, bead, sid, end, dry=False, meta=None):
    """-> (outcome, why, at): armed / would (dry-run) / refused / unknown / unverified (updated, read-back disagrees) / failed. ONE bd update, read back; the metadata read first is what the guards judge."""
    def left(cap):
        return max(1, min(cap, int(end - io.now())))
    if io.now() >= end:
        return "unknown", "time budget of the pass spent before this target", 0
    meta = meta if isinstance(meta, dict) else read_meta(io, cfg, bead, left(cfg.bd_t))  # the capture write's read-back already carries it
    if meta is None:
        return "unknown", "bead metadata unreadable", 0
    tpath = find_transcript(cfg.claude, sid)
    if not tpath:
        return "unknown", "transcript vanished", 0
    ok, why = arm_decision(cfg, meta, sid, tpath)
    stale = bool(meta.get("reset_committed_at")) and str(meta.get("continuation_reset_pending") or "").strip() != "true"  # a stamp nobody will ever complete: only produces a false "reset stalled" at the next boot
    if not ok:
        if stale and not dry and io.now() < end:
            io.run(cfg.bd + ["update", bead, "--unset-metadata", "reset_committed_at"], left(cfg.bd_t))  # best effort: the stamp is noise, the refusal is what matters
        return "refused", why, 0
    if dry:
        return "would", why, 0
    at = int(io.now())
    argv = cfg.bd + ["update", bead, "--set-metadata", "session_key=%s" % sid, "--set-metadata", "sleep_reason=%s" % CITY_STOP, "--set-metadata", "%s=%s" % (K_ARM_ID, sid), "--set-metadata", "%s=%d" % (K_ARM_AT, at)]
    if stale:
        argv += ["--unset-metadata", "reset_committed_at"]
    rc, _, err = io.run(argv, left(cfg.bd_t))
    if rc != 0:
        return "failed", "bd update rc=%s: %s" % (rc, (err or "").strip()[:100]), 0
    # falhou/ilegível (estouro, JSON ruim, valores diferentes) → "unverified": o update pode ter valido, então o chamador GUARDA o armado no estado e o desarme das rodadas normais limpa o sleep_reason se o reboot não vier
    back = read_meta(io, cfg, bead, left(cfg.bd_t))
    if back is None or back.get("session_key") != sid or back.get("sleep_reason") != CITY_STOP:
        return "unverified", "read-back does not show the arming (session_key=%r sleep_reason=%r)" % (None if back is None else back.get("session_key"), None if back is None else back.get("sleep_reason")), at
    return "armed", why, at


def parse_rfc3339(v):
    # vazio/ilegível → None (quem chama trata como "não sei se reiniciou": não conclui nada); só um instante lido vira número
    try:
        return datetime.strptime(str(v).strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def nudge_fresh(io, cfg, tname, prev, tmo):
    msg = ("O mini reiniciou e você subiu numa conversa NOVA. A conversa que estava aberta antes era %s (ficou no disco: `claude --resume %s` abre o histórico). "
           "Releia sua bead em andamento e o último handoff antes de seguir." % (prev, prev))
    rc, _, _ = io.run(cfg.gc + ["session", "nudge", tname, msg], tmo)
    return rc == 0


def check_boot(io, cfg, log, bead, tname, sid, ent, tmo, dry):
    """After a boot (normal passes, target live as `sid`): was an armed conversation resumed? Writes the verdict, nudges a fresh start once, or disarms a reboot that never came."""
    pend = ent.get("nudge") if isinstance(ent.get("nudge"), dict) else None
    if pend and (pend.get("sid") != sid or pend.get("tries", 0) >= NUDGE_TRIES):
        ent.pop("nudge")  # the session moved on to another conversation, or three tries were enough: never tell it about a conversation that is no longer the one it is in
        pend = None
    if pend and not dry:
        if nudge_fresh(io, cfg, tname, pend.get("prev"), tmo):
            log("NUDGED %s (%s): retry worked" % (bead, tname))
            ent["nudged"] = sid
            ent.pop("nudge")
        else:
            pend["tries"] = pend.get("tries", 0) + 1
        return
    arm = ent.get("armed") if isinstance(ent.get("armed"), dict) else None
    prev = arm.get("id") if arm else ent.get("cid")
    if not isinstance(prev, str) or not prev or (prev == sid and not arm):
        return
    meta = read_meta(io, cfg, bead, tmo)
    if meta is None:
        return  # cannot tell: the next pass asks again (armed stays, nothing is concluded)
    woke = parse_rfc3339(meta.get("last_woke_at"))
    since = arm.get("at") if arm and isinstance(arm.get("at"), (int, float)) else ent.get("at")
    since = since if isinstance(since, (int, float)) else 0
    restarted = woke is not None and woke > since
    if not restarted:
        if arm and io.now() - arm["at"] > cfg.disarm_s and not dry:
            if meta.get("sleep_reason") == CITY_STOP and meta.get(K_ARM_ID) == arm.get("id"):
                rc, _, err = io.run(cfg.bd + ["update", bead, "--unset-metadata", "sleep_reason"], tmo)
                if rc != 0:
                    log("FAILED %s (%s): could not remove the arming sleep_reason: %s" % (bead, tname, (err or "").strip()[:100]))
                    return
            log("DISARMED %s (%s): no restart %d s after arming (the reboot did not happen); sleep_reason=city-stop removed" % (bead, tname, int(io.now() - arm["at"])))
            ent.pop("armed", None)
        return
    ok = prev == sid
    if dry:
        log("WOULD record resume_result=%s for %s (%s): armed/previous %s, live %s" % ("ok" if ok else "fresh", bead, tname, prev, sid))
        return
    if not ok:
        if ent.get("nudged") != sid:
            sent = nudge_fresh(io, cfg, tname, prev, tmo)
            log("%s %s (%s): came back on %s, the conversation before was %s" % ("NUDGED" if sent else "NUDGE-FAILED", bead, tname, sid, prev))
            if sent:
                ent["nudged"] = sid
            else:
                ent["nudge"] = {"prev": prev, "sid": sid, "tries": 1}  # retried by the next passes, a few times
    else:
        log("RESUMED %s (%s): back in the same conversation %s" % (bead, tname, sid))
    rc, _, _ = io.run(cfg.bd + ["update", bead, "--set-metadata", "%s=%s" % (K_RES, "ok" if ok else "fresh"), "--set-metadata", "%s=%d" % (K_RES_AT, int(io.now()))], tmo)
    if rc == 0:
        ent.pop("armed", None)
    else:
        log("FAILED %s (%s): could not record resume_result (retried next pass)" % (bead, tname))


def run_pass(cfg, io, final=False, dry=False):
    """-> (exit code, counts). 0 evaluated · 3 could not evaluate (crew list or roster unreadable: nothing written)."""
    log = Log(cfg.log, dry)
    end = io.now() + (cfg.final_budget_s if final else cfg.budget_s)

    def left(cap):  # each call gets what is left of the pass budget, never less than 1 s
        return max(1, min(cap, int(end - io.now())))
    counts = dict.fromkeys(("targets", "wrote", "same", "absent", "unknown", "failed", "armed", "refused"), 0)
    jobs = []
    crews = crew_names(cfg.agents)
    roster = None
    if crews is not None:
        # the final pass has 20 s, and `gc session list` alone took 22-60 s at load 77: it asks the beads first, the other pass keeps gc first; each is the other's fallback
        for src in ((load_roster_bd, load_roster) if final else (load_roster, load_roster_bd)):
            roster = src(io, cfg, left(min(cfg.gc_t, 10) if final and src is load_roster_bd else cfg.gc_t))
            if roster is not None:
                break
    if roster is None:
        log("ERROR: cannot evaluate, nothing written: %s" % ("crew list (agents/) unreadable" if crews is None else "gc session list and bd query both unreadable"))
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
        if cfg.arm and not final and io.now() < end:
            check_boot(io, cfg, log, bead, tname, val, ent, left(cfg.bd_t), dry)  # BEFORE the write below: it still needs the id of the conversation that was here before
        at = ent.get("at") if isinstance(ent.get("at"), (int, float)) else 0
        if not (final or ent.get("cid") != val or io.now() - at >= cfg.refresh_s):
            counts["same"] += 1
            ent["note"] = ""
            continue
        if final:
            jobs.append((bead, tname, val, ent))  # the writes of different beads are independent bd calls: done side by side below
            continue
        if dry:
            counts["wrote"] += 1
            log("WOULD write %s (%s): %s -> %s" % (bead, tname, ent.get("cid") or "-", val))
            continue
        ok, why, _ = persist(io, cfg, bead, val, int(io.now()), left(cfg.bd_t))
        if not ok:
            counts["failed"] += 1
            log("FAILED %s (%s): %s" % (bead, tname, why))
            continue
        counts["wrote"] += 1
        if ent.get("cid") != val:
            log("WROTE %s (%s): %s -> %s" % (bead, tname, ent.get("cid") or "-", val))
        ent.update(cid=val, at=int(io.now()), note="")
    if jobs:
        def job(b, v):  # capture write, then (if it landed) the arming judged on the metadata that write read back
            md = None
            if not dry:
                ok, why, md = persist(io, cfg, b, v, int(io.now()), left(cfg.bd_t))
                if not ok:
                    return ("persist", why, 0)
            if not cfg.arm:
                return "off", "", 0
            try:
                return arm_one(io, cfg, b, v, end, dry, md)
            except Exception as ex:  # a surprise while judging must not hide that the capture write landed: this target is simply not armed
                return "unknown", "unexpected %s: %s" % (type(ex).__name__, ex), 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(cfg.workers, len(jobs)))) as pool:
            futs = [(b, t, v, e, pool.submit(job, b, v)) for b, t, v, e in jobs]
            for b, t, v, e, f in futs:
                try:
                    out, why, at = f.result()
                except Exception as ex:  # one target's surprise in the write must not blind the others
                    out, why, at = "persist", "unexpected %s: %s" % (type(ex).__name__, ex), 0
                if out == "persist":
                    counts["failed"] += 1
                    log("FAILED %s (%s): %s" % (b, t, why))
                    continue
                counts["wrote"] += 1
                if dry:
                    log("WOULD write %s (%s): %s -> %s" % (b, t, e.get("cid") or "-", v))
                else:
                    if e.get("cid") != v:
                        log("WROTE %s (%s): %s -> %s" % (b, t, e.get("cid") or "-", v))
                    e.update(cid=v, at=int(io.now()), note="")
                if out in ("armed", "unverified"):
                    e["armed"] = {"id": v, "at": at}
                if out == "armed":
                    counts["armed"] += 1
                    log("ARMED %s (%s): the next boot resumes %s (%s)" % (b, t, v, why))
                elif out == "would":
                    counts["armed"] += 1
                    log("WOULD arm %s (%s): %s (%s)" % (b, t, v, why))
                elif out in ("unverified", "failed"):
                    counts["failed"] += 1
                    log("FAILED %s (%s): arming %s: %s" % (b, t, out, why))
                elif out != "off":
                    counts["refused"] += 1
                    log("NOT ARMED %s (%s): %s%s — the engine default (a fresh start) stays" % (b, t, "unknown: " if out == "unknown" else "", why))
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
    print("%s alvos=%d gravou=%d igual=%d ausente=%d nao-sei=%d falhou=%d%s%s" % (tag, c["targets"], c["wrote"], c["same"], c["absent"], c["unknown"], c["failed"],
                                                                                " armou=%d recusou=%d" % (c["armed"], c["refused"]) if final else "", " (dry-run)" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
