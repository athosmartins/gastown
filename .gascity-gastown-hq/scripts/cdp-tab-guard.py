#!/usr/bin/env python3
"""cdp-tab-guard.py (ga-w7rcut) — closes HEAVY + IDLE tabs of the shared automation Chrome.

WHY (measured 2026-09-19): four renderers of the shared automation Chrome (:9222,
com.athos.chrome-cdp) reached 3.0 / 2.8 / 2.6 / 2.4 GB of FOOTPRINT (almost all of it
compressed) within ~11 minutes, pushing swap 6 -> 10 GB and the disk (swap lives on the
same APFS container as Dolt) from 10 GB to 2 GB. Cause: an agent's ad-hoc puppeteer
scripts did newPage()+goto(<60 MB map page>)+browser.disconnect() with no page.close();
disconnect() does NOT close the tab, so every run left one multi-GB renderer alive
(9 stale tabs at once, 07:55). The only existing net, chrome_cdp_watchdog.sh, caps
`ps rss` — which does not count compressed memory — and read "1433MB < cap" while the
real footprint was ~10.8 GB; and when it does fire it recycles the WHOLE Chrome, killing
every agent's tabs. This guard is the tab-level, footprint-based complement.

WHAT (per run; launchd StartInterval 60 s; single instance):
  1. Find the Chrome family whose main process carries --remote-debugging-port=<PORT>.
  2. Per renderer: FOOTPRINT (proc_pid_rusage ri_phys_footprint — the number Activity
     Monitor / `top mem` show, INCLUDING compressed pages) and CPU time.
  3. A renderer is HEAVY when footprint >= CEILING_MB. It is IDLE when its CPU has stayed
     below ACTIVE_CPU_MS_PER_MIN across the observed samples for >= IDLE_SEC (shorter,
     IDLE_SEC_PRESSURE, when Chrome's total footprint or system swap crosses a pressure
     line). A renderer seen for the first time is never idle.
  4. Only for heavy+idle renderers (the common run stops at step 3 and never touches CDP):
     if no renderer is burning CPU right now, connect over CDP and work out which tab lives
     in which renderer — run a fixed amount of WORK inside each page (self-calibrated to
     ~PROBE_MS of CPU; work-based because a wall-clock loop starves on a loaded box) and see
     whose CPU counter jumps. Close the one tab that owns the heavy renderer with
     Target.closeTarget, after re-confirming the placement. Never the Chrome process.

HOW WE KNOW A TAB IS "IN USE NOW" (the tradeoff, stated plainly): a tab is in use if its
renderer's CPU shows activity inside the idle window. A CDP client driving a tab (snapshot,
evaluate, navigate) costs CPU, so an actively driven tab keeps resetting its idle clock.
What this CANNOT see: an agent that holds a heavy tab open and stays completely silent for
longer than the idle window (e.g. waiting on a human) — that tab can be closed. The ceiling
(1.5 GB, far above any normal page) plus the 10 min / 3 min windows bound that risk to
pathological pages. `attached` (a CDP client is connected) is deliberately NOT treated as
"in use": under playwright-mcp every tab is attached while any agent session is connected,
so honouring it would disable the guard in exactly the incident it exists for. It is logged.

THREE-STATE RULE: unknown never means safe-to-close. Each of these is logged and leaves
every tab untouched: unreadable renderer; renderer no tab could be placed in (UNMAPPED); a
renderer shared by several tabs (SHARED); a chrome:// page; the last remaining page; a page
that answered but could not be placed (PARTIAL_PROBE — it might share the renderer); a
placement that does not reproduce right before closing (UNCONFIRMED); a renderer burning CPU
during placement (DEFER_NOISY); a state file we cannot parse; any CDP failure. A page that
cannot run JS at all (crashed/wedged) is `dead`, not `unresolved`: every page in a renderer
shares its main thread, so a dead page cannot share a renderer with a page that answered.

SAFETY VALVES: single-instance flock; MAX_CLOSE_RUN / MAX_CLOSE_HOUR caps; never the last
page (playwright connectOverCDP needs >= 1 page); kill switch = ACTION=0 or the file
<state_dir>/DISABLED (both downgrade to a dry run that logs WOULD_CLOSE); a hard 120 s alarm.

KNOWN LIMITS: (1) a renderer that steadily burns >= 15 ms of CPU per 0.5 s defers ALL closes
(DEFER_NOISY repeating in the log is the tell); (2) only `page` targets are closable — a heavy
renderer hosting only iframes/extension pages stays UNMAPPED; (3) the silent-tab case above.

OUT OF SCOPE: chrome_cdp_watchdog.sh keeps its whole-Chrome recycle and its `ps rss` cap
(moving that cap to footprint is a separate follow-up); the MBP Chrome (:9223).

CONFIG (env, CDP_TAB_GUARD_*; garbage or non-positive values fall back to the default so a
typo can never lower the ceiling to 0): PORT 9222 · ACTION 1 · CEILING_MB 1536 · IDLE_SEC 600
· IDLE_SEC_PRESSURE 180 · PRESSURE_TOTAL_MB 6144 · PRESSURE_SWAP_MB 8192 · ACTIVE_CPU_MS_PER_MIN
150 · MAX_GAP_SEC 300 · MAX_CLOSE_RUN 2 · MAX_CLOSE_HOUR 8 · MIN_PAGES_KEEP 1 · PROBE_MS 50 (CPU-ms
of work per probe) · STATE_DIR / LOG / LOCK (default under $GC_CITY_PATH/.gc).

Files: <state_dir>/state.json (idle tracking), status.json (heartbeat for watchers),
guard.lock, DISABLED (kill switch); log: <city>/.gc/logs/cdp-tab-guard.log.

Test: scripts/cdp-tab-guard.selftest.sh (pure logic + a real throwaway headless Chrome on a
private port; never touches :9222).
"""
from __future__ import annotations

import base64
import ctypes
import ctypes.util
import fcntl
import hashlib
import json
import math
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import traceback
import urllib.request

PROTECTED_SCHEMES = ("chrome:", "chrome-extension:", "chrome-untrusted:", "chrome-search:",
                     "devtools:", "view-source:")
HARD_TIMEOUT_S = 120
LOG_ROTATE_BYTES = 2 * 1024 * 1024
HEARTBEAT_EVERY_S = 600


# ─────────────────────────────── configuration ───────────────────────────────


def _num(env, name, default, cast, lo, strict=False):
    raw = env.get("CDP_TAB_GUARD_" + name.upper())
    try:
        v = cast(str(raw).strip())
    except (TypeError, ValueError):
        return default
    if isinstance(v, float) and not math.isfinite(v):
        return default
    if (v <= lo) if strict else (v < lo):
        return default
    return v


class Config:
    """Env-driven knobs. Non-positive / unparsable values fall back to the default."""

    @classmethod
    def from_env(cls, env):
        c = cls()
        c.port = _num(env, "port", 9222, int, 1)
        c.action = _num(env, "action", 1, int, 0)
        c.ceiling_mb = _num(env, "ceiling_mb", 1536.0, float, 0.0, strict=True)
        c.idle_sec = _num(env, "idle_sec", 600, int, 0)
        c.idle_sec_pressure = _num(env, "idle_sec_pressure", 180, int, 0)
        c.pressure_total_mb = _num(env, "pressure_total_mb", 6144.0, float, 0.0, strict=True)
        c.pressure_swap_mb = _num(env, "pressure_swap_mb", 8192.0, float, 0.0, strict=True)
        c.active_cpu_ms_per_min = _num(env, "active_cpu_ms_per_min", 150.0, float, 0.0, strict=True)
        c.max_gap_sec = _num(env, "max_gap_sec", 300, int, 0, strict=True)
        c.max_close_run = _num(env, "max_close_run", 2, int, 0)
        c.max_close_hour = _num(env, "max_close_hour", 8, int, 0)
        c.min_pages_keep = _num(env, "min_pages_keep", 1, int, 1)
        c.probe_ms = _num(env, "probe_ms", 50, int, 0, strict=True)   # CPU-ms of work per probe
        city = env.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        c.state_dir = env.get("CDP_TAB_GUARD_STATE_DIR") or os.path.join(city, ".gc", "cdp-tab-guard")
        c.log_path = env.get("CDP_TAB_GUARD_LOG") or os.path.join(city, ".gc", "logs", "cdp-tab-guard.log")
        c.lock_path = env.get("CDP_TAB_GUARD_LOCK") or os.path.join(c.state_dir, "guard.lock")
        c.state_path = os.path.join(c.state_dir, "state.json")
        c.status_path = os.path.join(c.state_dir, "status.json")
        c.disabled_path = os.path.join(c.state_dir, "DISABLED")
        return c


# ───────────────────────────── process measurement ─────────────────────────────


def parse_family(ps_text, port):
    """(main_pid | None, [renderer pids]) of the Chrome whose main process carries
    --remote-debugging-port=<port>. Exact token match, Chrome executable only."""
    flag = "--remote-debugging-port=%d" % port
    rows = []
    for line in ps_text.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    main = None
    for pid, _ppid, cmd in rows:
        toks = cmd.split()
        exe = os.path.basename(cmd.split(" --", 1)[0])
        if (flag in toks and not any(t.startswith("--type=") for t in toks)
                and (exe.startswith("Google Chrome") or exe.startswith("Chromium") or exe == "chrome")):
            main = pid
            break
    if main is None:
        return (None, [])
    return (main, [pid for pid, ppid, cmd in rows if ppid == main and "--type=renderer" in cmd.split()])


class _RUsageV0(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime")]


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libs = {}


def _sys_libs():
    if not _libs:
        proc = ctypes.CDLL(ctypes.util.find_library("proc") or "libproc.dylib", use_errno=True)
        proc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libSystem.dylib")
        tb = _Timebase()
        libc.mach_timebase_info(ctypes.byref(tb))
        _libs.update(proc=proc, numer=tb.numer or 1, denom=tb.denom or 1)
    return _libs


def read_proc(pid):
    """{'footprint_mb', 'cpu_ms', 'start'} or None when the process cannot be read.
    footprint = ri_phys_footprint (resident + compressed). None is 'unmeasured', never 0."""
    try:
        libs = _sys_libs()
        ri = _RUsageV0()
        if libs["proc"].proc_pid_rusage(int(pid), 0, ctypes.byref(ri)) != 0:
            return None
        cpu_ns = (ri.ri_user_time + ri.ri_system_time) * libs["numer"] // libs["denom"]
        return {"footprint_mb": ri.ri_phys_footprint / 1048576.0, "cpu_ms": cpu_ns / 1e6,
                "start": int(ri.ri_proc_start_abstime)}
    except Exception:
        return None


def read_swap_mb():
    """System swap in use (MB) or None. Unmeasured is not 'no swap'."""
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True,
                             timeout=5).stdout
        m = re.search(r"used = ([\d.]+)([MGK])", out)
        if not m:
            return None
        return float(m.group(1)) * {"K": 1 / 1024.0, "M": 1.0, "G": 1024.0}[m.group(2)]
    except Exception:
        return None


# ─────────────────────────────── decision logic ────────────────────────────────


def step_idle(entry, sample, now, cfg):
    """Track how long a renderer's CPU has been quiet. Returns (new_entry, idle_for_s).
    Anything we cannot vouch for (first sight, recycled pid, a hole in observation, a
    clock or counter that went backwards) restarts the clock: unknown is never idle."""
    fresh = {"start": sample["start"], "idle_since": now, "last_ts": now, "last_cpu_ms": sample["cpu_ms"]}
    if not entry or entry.get("start") != sample["start"]:
        return fresh, 0
    gap = now - entry["last_ts"]
    delta = sample["cpu_ms"] - entry["last_cpu_ms"]
    if gap <= 0 or gap > cfg.max_gap_sec or delta < 0:
        return fresh, 0
    active = (delta / gap * 60.0) >= cfg.active_cpu_ms_per_min
    idle_since = now if active else entry["idle_since"]
    return ({"start": sample["start"], "idle_since": idle_since, "last_ts": now,
             "last_cpu_ms": sample["cpu_ms"]}, int(now - idle_since))


def classify(fp_mb, idle_for_s, pressure, cfg):
    """OK | HEAVY_NOT_IDLE | HEAVY_IDLE. idle_for_s == 0 (first sight / just active) is never idle."""
    if fp_mb < cfg.ceiling_mb:
        return "OK"
    need = cfg.idle_sec_pressure if pressure else cfg.idle_sec
    return "HEAVY_IDLE" if (idle_for_s > 0 and idle_for_s >= need) else "HEAVY_NOT_IDLE"


def is_pressure(total_mb, swap_mb, cfg):
    return ((total_mb is not None and total_mb >= cfg.pressure_total_mb)
            or (swap_mb is not None and swap_mb >= cfg.pressure_swap_mb))


def pick_probe_pid(deltas_ms, probe_ms):
    """Which renderer ran the probe? The one whose CPU jumped — but only if the jump is
    convincing (>= 40% of the probe) and unambiguous (runner-up < 50% of the winner)."""
    if not deltas_ms:
        return None
    ranked = sorted(deltas_ms.items(), key=lambda kv: -kv[1])
    top_pid, top = ranked[0]
    if top * 10 < probe_ms * 4:
        return None
    if len(ranked) > 1 and ranked[1][1] * 2 >= top:
        return None
    return top_pid


def decide(candidates, mapping, targets, cfg, closes_last_hour):
    """Pure safety core. candidates: [{'pid','fp_mb','idle_for_s'}] (heavy+idle renderers);
    mapping: {pid: [target ids the probe placed in that renderer]}; targets: {id: TargetInfo}.
    Returns one decision per candidate, heaviest first: CLOSE, or SKIP with a reason."""
    out = []
    pages_left = sum(1 for t in targets.values() if t.get("type") == "page")
    hour_room = cfg.max_close_hour - closes_last_hour
    room = min(cfg.max_close_run, hour_room)
    closed = 0
    for c in sorted(candidates, key=lambda c: (-c["fp_mb"], c["pid"])):
        d = {"pid": c["pid"], "fp_mb": c["fp_mb"], "idle_for_s": c["idle_for_s"], "target": None,
             "action": "SKIP", "reason": None}
        infos = [targets[i] for i in (mapping.get(c["pid"]) or []) if i in targets]
        if not infos:
            d["reason"] = "UNMAPPED"
        elif len(infos) > 1:
            d["reason"] = "SHARED"
            d["tabs"] = [t["targetId"] for t in infos]
        else:
            t = infos[0]
            d["target"] = t["targetId"]
            if t.get("type") != "page":
                d["reason"] = "NOT_A_PAGE"
            elif (t.get("url") or "").startswith(PROTECTED_SCHEMES):
                d["reason"] = "PROTECTED_URL"
            elif closed >= room:
                d["reason"] = "CAP_HOUR" if hour_room <= cfg.max_close_run else "CAP_RUN"
            elif pages_left - 1 < cfg.min_pages_keep:
                d["reason"] = "KEEP_LAST_PAGE"
            else:
                d["action"], d["reason"] = "CLOSE", "HEAVY_IDLE"
                closed += 1
                pages_left -= 1
        out.append(d)
    return out


# ───────────────────────────────── CDP client ──────────────────────────────────


class CDPError(Exception):
    pass


class CDPClient:
    """Minimal stdlib websocket client for the browser endpoint. No Origin header is sent:
    Chrome answers 403 to a websocket handshake carrying an Origin it was not told to allow."""

    def __init__(self, sock, timeout):
        self.sock = sock
        self.timeout = timeout
        self._id = 0

    @classmethod
    def connect(cls, port, timeout=5.0):
        with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % port, timeout=timeout) as r:
            url = json.loads(r.read().decode())["webSocketDebuggerUrl"]
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)$", url)
        if not m:
            raise CDPError("unexpected websocket url: %r" % url)
        host, wsport, path = m.group(1), int(m.group(2)), m.group(3)
        sock = socket.create_connection((host, wsport), timeout=timeout)
        try:
            key = base64.b64encode(os.urandom(16)).decode()
            sock.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
                          % (path, host, wsport, key)).encode())
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = sock.recv(4096)
                if not chunk:
                    raise CDPError("websocket handshake: connection closed")
                head += chunk
                if len(head) > 65536:
                    raise CDPError("websocket handshake: oversized response")
            status = head.split(b"\r\n", 1)[0]
            want = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            if b" 101 " not in status or want not in head:
                raise CDPError("websocket handshake refused: %s" % status.decode(errors="replace"))
        except Exception:
            sock.close()
            raise
        return cls(sock, timeout)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def _read(self, n, deadline):
        buf = b""
        while len(buf) < n:
            left = deadline - time.time()
            if left <= 0:
                raise CDPError("timed out waiting for the browser")
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(n - len(buf))
            except socket.timeout:
                raise CDPError("timed out waiting for the browser")
            if not chunk:
                raise CDPError("connection closed by the browser")
            buf += chunk
        return buf

    def _send_text(self, text):
        data = text.encode()
        n = len(data)
        head = bytearray([0x81])
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", n)
        mask = os.urandom(4)
        head += mask
        self.sock.settimeout(self.timeout)
        self.sock.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _recv_message(self, deadline):
        payload = b""
        while True:
            b1, b2 = self._read(2, deadline)
            fin, opcode, length = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2, deadline))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8, deadline))[0]
            if b2 & 0x80:
                mask = self._read(4, deadline)
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(length, deadline)))
            else:
                data = self._read(length, deadline)
            if opcode == 0x8:
                raise CDPError("browser closed the websocket")
            if opcode == 0x9:                       # ping -> pong
                self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            if opcode == 0xA:
                continue
            payload += data
            if fin:
                return payload.decode()

    def call(self, method, params=None, session_id=None, timeout=None):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params or {}}
        if session_id:
            msg["sessionId"] = session_id
        deadline = time.time() + (timeout if timeout is not None else self.timeout)
        self._send_text(json.dumps(msg))
        while True:
            resp = json.loads(self._recv_message(deadline))
            if resp.get("id") == self._id:
                if "error" in resp:
                    raise CDPError("%s: %s" % (method, resp["error"]))
                return resp.get("result", {})


PROBE_N_START, PROBE_N_MIN, PROBE_N_MAX = 18_000_000, 2_000_000, 150_000_000


class Prober:
    """Places tabs in renderers: run a fixed amount of WORK inside a page and see whose CPU
    counter jumped. Work-based on purpose — a wall-clock loop gets only a fraction of a CPU on
    a starved box and would fall under the confidence floor exactly when the machine needs the
    guard (measured 2026-09-19: load average 44 on 10 cores; 300 ms of CPU took 2-4 s of wall).
    The amount of work self-calibrates to `probe_ms` of CPU from each probe's own result."""

    def __init__(self, client, renderer_pids, probe_ms):
        self.client = client
        self.pids = sorted(renderer_pids)
        self.probe_ms = probe_ms
        self.n = PROBE_N_START

    def _cpu(self):
        return {p: (read_proc(p) or {}).get("cpu_ms") for p in self.pids}

    def probe(self, tid):
        """Per-renderer CPU deltas (ms) while `tid` runs the probe. Raises on CDP failure —
        including a page that cannot answer a trivial evaluate within 5 s (a crashed tab never
        answers; without this ping one would cost the whole probe timeout on every run)."""
        js = "(function(n){var x=0;for(var i=0;i<n;i++)x+=Math.sqrt(i);return x})(%d)" % self.n
        before = self._cpu()
        sid = self.client.call("Target.attachToTarget", {"targetId": tid, "flatten": True})["sessionId"]
        try:
            self.client.call("Runtime.evaluate", {"expression": "1", "returnByValue": True},
                             session_id=sid, timeout=5)
            self.client.call("Runtime.evaluate", {"expression": js, "returnByValue": True},
                             session_id=sid, timeout=30)
        finally:
            try:
                self.client.call("Target.detachFromTarget", {"sessionId": sid}, timeout=5)
            except Exception:
                pass
        after = self._cpu()
        deltas = {p: after[p] - before[p] for p in self.pids
                  if before.get(p) is not None and after.get(p) is not None}
        top = max(deltas.values(), default=0.0)
        scale = max(0.25, min(4.0, self.probe_ms / max(top, 1e-3)))
        self.n = int(max(PROBE_N_MIN, min(PROBE_N_MAX, self.n * scale)))
        return deltas

    def map_pages(self, page_ids, budget_s=45.0):
        """(mapping {renderer pid: [page ids]}, unresolved [page ids], dead [page ids]).
        dead       = the page could not run JS at all (crashed / wedged / gone). Every page in a
                     renderer shares its main thread, so a dead page cannot share a renderer with a
                     page that did answer — it never blocks a close.
        unresolved = the page answered but could not be placed convincingly after 3 tries, or the
                     budget ran out before it was probed. It MAY share a candidate's renderer, so
                     the caller must not close anything while any exist."""
        mapping, unresolved, dead = {}, [], []
        end = time.time() + budget_s
        for tid in page_ids:
            pid, failed = None, False
            for _attempt in range(3):
                if time.time() > end:
                    break
                try:
                    pid = pick_probe_pid(self.probe(tid), self.probe_ms)
                except Exception:
                    failed = True
                    break
                if pid is not None:
                    break
            if pid is not None:
                mapping.setdefault(pid, []).append(tid)
            elif failed:
                dead.append(tid)
            else:
                unresolved.append(tid)
        return mapping, unresolved, dead


def busy_renderers(pids, window_s=0.5, max_ms=15.0):
    """Renderers burning CPU right now (>= max_ms in window_s; an idle page sits under 2 ms).
    Placing tabs by CPU while a neighbour burns CPU can mis-place a tab, so the caller defers."""
    first = {p: (read_proc(p) or {}).get("cpu_ms") for p in pids}
    time.sleep(window_s)
    second = {p: (read_proc(p) or {}).get("cpu_ms") for p in pids}
    return sorted(p for p in pids if first.get(p) is not None and second.get(p) is not None
                  and second[p] - first[p] >= max_ms)


# ───────────────────────────── state, logging, run ─────────────────────────────


def _clean_url(u):
    return re.sub(r"[?#].*$", "", u or "")[:120]


def _clean_title(s):
    return (s or "").replace("\n", " ")[:40]


def _write_json_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def load_state(cfg, log):
    try:
        with open(cfg.state_path) as f:
            st = json.load(f)
        if not isinstance(st, dict):
            raise ValueError("state is not an object")
        return st
    except FileNotFoundError:
        return {}
    except Exception as ex:
        log("STATE unreadable (%s) — starting fresh; nothing will be closed until idle time is re-observed"
            % type(ex).__name__)
        return {}


def make_logger(cfg, verbose=False):
    def log(msg):
        line = "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        try:
            os.makedirs(os.path.dirname(cfg.log_path), exist_ok=True)
            try:
                if os.path.getsize(cfg.log_path) > LOG_ROTATE_BYTES:
                    os.replace(cfg.log_path, cfg.log_path + ".1")
            except OSError:
                pass
            with open(cfg.log_path, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass
        if verbose:
            print(line)
    return log


def connected_clients(port, main_pid):
    """Best-effort attribution: processes with an established connection to the CDP port."""
    try:
        out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:ESTABLISHED", "-Fpc"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    seen, cur = {}, None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            cur = int(line[1:])
            seen.setdefault(cur, "")
        elif line.startswith("c") and cur is not None:
            seen[cur] = line[1:]
    return [(p, c) for p, c in seen.items() if p != main_pid]


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _target_ids(client):
    return {t["targetId"] for t in client.call("Target.getTargets")["targetInfos"]}


def act(cfg, state, candidates, renderer_pids, now, live, log):
    """Connect, map tabs to renderers, decide, and (when live) close. Returns closes made."""
    made = 0
    noisy = busy_renderers(sorted(renderer_pids))
    if noisy:
        log("DEFER_NOISY renderer(s) %s are burning CPU right now — placing tabs by CPU could mis-place "
            "one, so no tab is probed or closed this run" % noisy)
        return 0
    client = CDPClient.connect(cfg.port, timeout=10)
    try:
        infos = client.call("Target.getTargets")["targetInfos"]
        targets = {t["targetId"]: t for t in infos}
        page_ids = [t["targetId"] for t in infos if t.get("type") == "page"]
        prober = Prober(client, renderer_pids, cfg.probe_ms)
        mapping, unresolved, dead = prober.map_pages(page_ids)
        log("PROBE pages=%d placed=%d unresolved=%d dead=%d" % (
            len(page_ids), sum(len(v) for v in mapping.values()), len(unresolved), len(dead)))
        if unresolved:
            # An unresolved page might share a candidate's renderer, so no candidate can be proven
            # to own its tab exclusively. Unknown is never safe-to-close.
            for c in candidates:
                log("SKIP PARTIAL_PROBE pid=%d fp=%.0fMB idle=%ds unresolved_pages=%d/%d" % (
                    c["pid"], c["fp_mb"], c["idle_for_s"], len(unresolved), len(page_ids)))
            return 0
        closes = [t for t in state.get("closes", []) if now - t < 3600]
        decisions = decide(candidates, mapping, targets, cfg, len(closes))
        for d in decisions:
            t = targets.get(d["target"]) if d["target"] else None
            what = ("pid=%d fp=%.0fMB idle=%ds" % (d["pid"], d["fp_mb"], d["idle_for_s"]))
            if t:
                what += " target=%s attached=%s url=%s title=%r" % (
                    t["targetId"][:8], t.get("attached"), _clean_url(t.get("url")), _clean_title(t.get("title")))
            if d.get("tabs"):
                what += " tabs=%s" % [_clean_url(targets[i].get("url")) for i in d["tabs"]]
            if d["action"] != "CLOSE":
                log("SKIP %s %s" % (d["reason"], what))
                continue
            if not live:
                log("WOULD_CLOSE %s" % what)
                continue
            try:
                confirmed = pick_probe_pid(prober.probe(d["target"]), cfg.probe_ms) == d["pid"]
            except Exception:
                confirmed = False
            if not confirmed:
                log("SKIP UNCONFIRMED %s (placement did not reproduce right before closing)" % what)
                continue
            client.call("Target.closeTarget", {"targetId": d["target"]})
            gone = False
            for _ in range(24):
                if d["target"] not in _target_ids(client):
                    gone = True
                    break
                time.sleep(0.25)
            exited = False
            for _ in range(24):
                if not _pid_alive(d["pid"]):
                    exited = True
                    break
                time.sleep(0.25)
            if gone:
                closes.append(now)
                made += 1
                log("CLOSED %s renderer_exited=%s" % (what, exited))
            else:
                log("CLOSE_INEFFECTIVE %s (target still listed 6s after closeTarget)" % what)
        state["closes"] = closes
    finally:
        client.close()
    return made


def run_once(cfg, verbose=False):
    log = make_logger(cfg, verbose)
    os.makedirs(cfg.state_dir, exist_ok=True)
    lock = open(cfg.lock_path, "a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("SKIP locked (another cdp-tab-guard run is in progress)")
        return 0
    now = time.time()
    state = load_state(cfg, log)
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, timeout=15).stdout
    main_pid, rends = parse_family(ps, cfg.port)
    if main_pid is None:
        log("UNMEASURED no Chrome main process with --remote-debugging-port=%d in `ps` — "
            "nothing was evaluated, nothing was closed" % cfg.port)
        return 0

    samples = {pid: read_proc(pid) for pid in rends}
    # A renderer that exited between `ps` and the read is normal churn; only a live process we
    # cannot read is worth reporting.
    unreadable = sorted(pid for pid, s in samples.items() if s is None and _pid_alive(pid))
    old = state.get("pids") or {}
    new_pids, evals = {}, []
    for pid, s in samples.items():
        if s is None:
            continue
        entry, idle_for = step_idle(old.get(str(pid)), s, now, cfg)
        new_pids[str(pid)] = entry
        evals.append({"pid": pid, "fp_mb": s["footprint_mb"], "idle_for_s": idle_for})
    total_mb = sum(e["fp_mb"] for e in evals)
    max_mb = max([e["fp_mb"] for e in evals] or [0.0])
    swap_mb = read_swap_mb()
    pressure = is_pressure(total_mb, swap_mb, cfg)
    need = cfg.idle_sec_pressure if pressure else cfg.idle_sec

    heavy = []
    for e in evals:
        cls = classify(e["fp_mb"], e["idle_for_s"], pressure, cfg)
        if cls != "OK":
            heavy.append((cls, e))
            log("%s pid=%d fp=%.0fMB idle=%ds need=%ds pressure=%s" % (cls, e["pid"], e["fp_mb"], e["idle_for_s"], need, pressure))
    if unreadable:
        log("UNREADABLE renderer pid(s) %s — footprint unknown, left alone" % unreadable)
    if heavy:
        cl = connected_clients(cfg.port, main_pid)
        log("CDP clients now: %s" % ("unknown" if cl is None else
                                     (", ".join("%d:%s" % (p, c) for p, c in cl[:8]) or "none")))

    killswitch = os.path.exists(cfg.disabled_path)
    live = cfg.action == 1 and not killswitch
    if killswitch and any(c == "HEAVY_IDLE" for c, _ in heavy):
        log("kill switch present (%s) — dry run" % cfg.disabled_path)
    candidates = [e for c, e in heavy if c == "HEAVY_IDLE"]
    closed = 0
    if candidates:
        try:
            closed = act(cfg, state, candidates, rends, now, live, log)
        except Exception as ex:
            log("ERROR acting on %d heavy idle renderer(s): %s: %s — nothing closed by this run's failure path"
                % (len(candidates), type(ex).__name__, ex))

    state["v"] = 1
    state["pids"] = new_pids
    state["closes"] = [t for t in state.get("closes", []) if now - t < 3600]
    if not heavy and now - state.get("last_heartbeat", 0) >= HEARTBEAT_EVERY_S:
        log("ok renderers=%d total=%.0fMB max=%.0fMB heavy=0 swap=%s pressure=%s live=%s" % (
            len(evals), total_mb, max_mb, "?" if swap_mb is None else "%.0fMB" % swap_mb, pressure, live))
        state["last_heartbeat"] = now
    _write_json_atomic(cfg.state_path, state)
    _write_json_atomic(cfg.status_path, {
        "ts": now, "renderers": len(evals), "unreadable": len(unreadable), "total_mb": round(total_mb, 1),
        "max_mb": round(max_mb, 1), "heavy": len(heavy), "pressure": pressure, "live": live,
        "closed_this_run": closed, "closes_last_hour": len(state["closes"])})
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cfg = Config.from_env(os.environ)
    if "--dry-run" in argv or "-n" in argv:
        cfg.action = 0
    log = make_logger(cfg)

    def _timeout(_sig, _frm):
        log("ERROR run exceeded %ds — aborting (the next interval starts clean)" % HARD_TIMEOUT_S)
        os._exit(3)
    signal.signal(signal.SIGALRM, _timeout)
    signal.alarm(HARD_TIMEOUT_S)
    try:
        return run_once(cfg, verbose=("-v" in argv or "--verbose" in argv))
    except Exception as ex:
        log("ERROR unhandled %s: %s | %s" % (type(ex).__name__, ex, traceback.format_exc().strip().splitlines()[-1]))
        return 1


if __name__ == "__main__":
    sys.exit(main())
