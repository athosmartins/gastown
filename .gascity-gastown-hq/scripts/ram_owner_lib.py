"""ram_owner_lib — shared attribution engine for ram-owner-sampler.py and
ram-owner-report.py (bead ga-yr8vm).

WHY A SHARED LIB (deviation from this repo's usual single-file-per-script
convention, e.g. dolt-load-attributor.py): two different callers need the
IDENTICAL attribution logic — the periodic sampler (writes history) and the
report's live `--top` mode (used inline by ram-pressure-monitor.sh at alert
time, see item 4 of ga-yr8vm). Duplicating a tree-climb + regex label engine
in two files is exactly the kind of drift that gets one of them fixed and not
the other. Named with underscores (not hyphens) specifically so it can be
`import`ed normally — every hyphenated sibling script in this dir is invoked
as a subprocess instead, for the same reason.

ATTRIBUTION MODEL (per ga-yr8vm's ask: "por agente/sessão (não só por binário
'claude'), por daemon, por rig"):
  - owner: fine-grained identity — a gc session name (via --session-id in a
    claude process's own argv, joined against `gc session list --json`'s
    session_key) for agent/session RSS, or a daemon/script label (dolt-
    load-attributor.py's proven tree-climb-to-launchd-or-known-wrapper,
    reused near-verbatim here) for everything else.
  - rig: coarse identity — which rig's tree (HQ / whatsapp_automation /
    property_scrapers / other) the owner's cwd falls under. Free for claude
    sessions (gc session list already reports work_dir); costs one bounded
    `lsof -a -d cwd` per daemon owner otherwise, so callers should only
    resolve rig for a bounded top-N of owners, never every process.

UNRESOLVED ≠ SILENT (lesson inherited directly from the sibling bead in the
same epic, ga-lc17m — its own follow-up comment: "não-atribuído = total -
somado" must be its own explicit line, never absence). Any RSS this module
can't confidently attribute goes into the "unresolved" bucket, which the
caller must report as a number, never drop silently.

SAFETY: a `claude` process's argv can be enormous (the launch prompt is
passed inline — confirmed live, one instance ran ~45KB of embedded markdown
in argv). This module never stores or returns a raw, unbounded args string —
every args read is sliced to ARGS_HEAD_CHARS immediately after the one
`ps` snapshot, before any parsing or return.
"""
import json
import os
import re
import subprocess
import time

ARGS_HEAD_CHARS = 500  # --session-id / script path / gc|bd verb all live well within this
MAX_CLIMB = 30          # cycle/runaway guard, mirrors dolt-load-attributor's `seen` set intent
RIG_RESOLVE_TOP_N = 20  # bound on lsof calls for rig attribution — see sample()

HQ = "/Users/athos/gt/.gascity-gastown-hq"
RIG_STORES = {
    "hq": HQ,
    "whatsapp_automation": "/Users/athos/gt/whatsapp_automation",
    "property_scrapers": "/Users/athos/gt/property_scrapers",
}

_SESSION_ID_RE = re.compile(r"--session-id[= ]([0-9a-fA-F-]{36})")
_NOISE = re.compile(r'^(/bin/(ba)?sh|/usr/bin/env|timeout|gtimeout|sudo|nohup|xargs)\b')


def sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def _sh_checked(args, timeout=20):
    """Like sh(), but reports success/failure explicitly instead of collapsing
    a subprocess failure (nonzero exit, timeout, or exception) into the same
    "" a genuinely-empty-but-successful call would produce. Only
    sessions_by_key() needs this distinction today (see its docstring) — the
    other sh() callers already treat a failure as an honest per-field
    "unknown" (None) without ever asserting it as a false confirmed value."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, r.stdout
    except Exception:
        return False, ""


def ps_snapshot(fixture_path=None):
    """One atomic ps read: pid -> {ppid, rss_kb, comm, args_head}.

    fixture_path (test seam): a file with one `pid ppid rss comm args...` row
    per line, same shape `ps -eo pid=,ppid=,rss=,comm=,args=` produces, so
    selftests never have to shell out to real `ps`.
    """
    if fixture_path:
        try:
            with open(fixture_path) as f:
                out = f.read()
        except Exception:
            out = ""
    else:
        out = sh(["ps", "-eo", "pid=,ppid=,rss=,comm=,args="], timeout=20)
    tbl = {}
    for ln in out.splitlines():
        parts = ln.split(None, 4)
        if len(parts) < 5:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        comm, args = parts[3], parts[4]
        tbl[pid] = {"ppid": ppid, "rss_kb": rss, "comm": comm, "args_head": args[:ARGS_HEAD_CHARS]}
    return tbl


def sessions_by_key(fixture_path=None):
    """session_key -> {name, template, work_dir} from `gc session list --json`,
    plus an ok flag distinguishing "confirmed" from "could not determine".

    Returns (by_key, ok). ok=False means the underlying source (the live `gc`
    call, or a supplied fixture file) could not be read/parsed — by_key is {}
    in that case, indistinguishable BY SHAPE from a genuine "zero live
    sessions" reading, so callers MUST check ok before treating an empty
    by_key as confirmed rather than unknown. Collapsing the two was the exact
    gap ga-yr8vm's gate review caught: a transient `gc` failure silently
    degraded every claude process's owner_of() resolution into the generic
    "claude (no session-id match)" bucket — indistinguishable from a real
    no-session-id process — with no signal anywhere that the LOOKUP failed,
    not the process. A fixture that parses successfully, even to an empty
    list, reports ok=True: a deliberately empty test fixture is a valid
    confirmed-zero input, not a failure.

    fixture_path (test seam): a JSON file shaped like the real command's
    {"sessions": [...]} (or a bare list) output.
    """
    if fixture_path:
        try:
            with open(fixture_path) as f:
                d = json.load(f)
            ok = True
        except Exception:
            d, ok = [], False
    else:
        got, out = _sh_checked(["gc", "session", "list", "--json"], timeout=25)
        if got:
            try:
                d = json.loads(out or "[]")
                ok = True
            except Exception:
                d, ok = [], False
        else:
            d, ok = [], False
    sessions = d.get("sessions", d) if isinstance(d, dict) else d
    by_key = {}
    for s in sessions or []:
        k = s.get("session_key")
        if not k:
            continue
        by_key[k] = {
            "name": s.get("name") or s.get("session_name") or "?",
            "template": s.get("template") or "?",
            "work_dir": s.get("work_dir") or "",
            "last_active": s.get("last_active") or s.get("created_at") or "",
        }
    return by_key, ok


def label(args_head):
    """Short, stable label from a (bounded) command line. Ported from
    dolt-load-attributor.py's label() — same three shapes cover the vast
    majority of this city's daemons/scripts, so reuse rather than reinvent."""
    if not args_head:
        return "?"
    a = args_head.strip()
    m = re.search(r'/([a-zA-Z0-9_-]+)\.(py|sh)\b', a)
    if m:
        return m.group(1)
    m = re.search(r'\bgc\s+([a-z-]+(?:\s+[a-z-]+)?)', a)
    if m:
        return "gc " + m.group(1)
    m = re.search(r'\bbd\s+([a-z-]+)', a)
    if m:
        return "bd " + m.group(1)
    tok = a.split()[0] if a.split() else a
    return os.path.basename(tok)[:40]


def owner_of(pid, tbl, sess_by_key):
    """Returns (owner_label, kind, work_dir_or_None). kind in {"session","daemon","dolt","?"}.

    Session attribution (claude): read --session-id straight out of the
    process's OWN argv (present near the front, well inside ARGS_HEAD_CHARS)
    and join against `gc session list`'s session_key — no tmux/lsof hop
    needed, and no risk of the huge-embedded-prompt tail ever being touched.

    Daemon attribution (everything else): dolt-load-attributor's tree climb
    — parent is launchd => this process IS the service, label its own args;
    a generic client (bd/gc/python wrapper) climbs further; anything else
    stops and labels itself.
    """
    seen = set()
    cur = pid
    hops = 0
    while cur in tbl and cur not in seen and hops < MAX_CLIMB:
        seen.add(cur)
        hops += 1
        node = tbl[cur]
        comm_base = os.path.basename(node["comm"])
        if comm_base == "claude":
            m = _SESSION_ID_RE.search(node["args_head"])
            if m and m.group(1) in sess_by_key:
                s = sess_by_key[m.group(1)]
                return s["name"], "session", s["work_dir"]
            return "claude (no session-id match)", "session", None
        if comm_base == "dolt":
            return "dolt", "dolt", None
        ppid = node["ppid"]
        pargs = tbl.get(ppid, {}).get("args_head", "")
        if "launchd" in pargs or ppid <= 1:
            return label(node["args_head"]), "daemon", None
        base = os.path.basename(node["args_head"].split()[0]) if node["args_head"].split() else ""
        if base in ("bd", "gc", "beads", "python", "python3", "Python") or _NOISE.match(node["args_head"]):
            cur = ppid
            continue
        return label(node["args_head"]), "daemon", None
    return label(tbl.get(pid, {}).get("args_head", "")), "?", None


def resolve_rig(work_dir):
    """Rig name from a cwd/work_dir, by prefix match against RIG_STORES. Free
    (no subprocess) — callers already have work_dir for claude sessions from
    `gc session list`, or fetch it themselves (once, bounded) via
    `lsof -a -d cwd -p <pid>` for daemon owners worth the cost."""
    if not work_dir:
        return None
    for rig, root in RIG_STORES.items():
        if work_dir == root or work_dir.startswith(root + "/"):
            return rig
    return "other"


def cwd_of_pid(pid, timeout=5):
    """Bounded, single-pid lsof cwd lookup. Only call this for a small,
    deliberate set of owners (e.g. top-N daemons) — never per-process; lsof
    cost scales with how many times you call it, not with what it returns."""
    out = sh(["lsof", "-a", "-d", "cwd", "-p", str(pid)], timeout=timeout)
    lines = out.splitlines()
    if len(lines) < 2:
        return None
    # header: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME — NAME is last field
    fields = lines[1].split()
    return fields[-1] if fields else None


def sample(now=None, ps_fixture=None, sessions_fixture=None, compute_rig=True):
    """One full attributed snapshot: RSS aggregated by owner (and, unless
    compute_rig=False, by rig too), plus swap/free context. Pure aside from
    the (fixture-swappable) subprocess calls in ps_snapshot()/
    sessions_by_key()/vm-stat/swap reads below.

    compute_rig=False skips the by_rig breakdown (and its bounded-but-real
    lsof cost) entirely — for callers that only want by_owner, most notably
    ram-owner-report.py's --top live mode, which ram-pressure-monitor.sh
    calls INLINE at alert time: spending extra subprocess calls at the exact
    moment the machine is already under RAM pressure is the wrong trade."""
    now = now if now is not None else int(time.time())
    tbl = ps_snapshot(ps_fixture)
    if not tbl:
        # An empty ps table means `ps` itself failed/returned nothing — the
        # machine cannot legitimately have zero running processes. Returning
        # a normal-shaped record with total_rss_kb=0, by_owner={} here would
        # be indistinguishable from "measured, genuinely near-zero," and
        # would poison growth-since-last (a false -100% dip immediately
        # followed by a false +inf% recovery on the next real sample) and
        # historical medians (the fixture-driven test above only exercises
        # the success path, so this specific failure shape would have
        # shipped uncaught). Same "measurement gap, not a real reading"
        # idiom as machine-utilization-sampler.py's dolt_ok()-failure state.
        return {"ts": now, "error": "ps_snapshot_empty", "total_rss_kb": None,
                "unresolved_kb": None, "n_procs": 0, "swap_used_mb": None,
                "swap_total_mb": None, "free_pct": None, "by_owner": {},
                "owner_kind": {}, "by_rig": {}, "sessions_lookup_failed": None}
    sess, sess_ok = sessions_by_key(sessions_fixture)

    by_owner = {}
    owner_kind = {}
    owner_rss_pid = {}  # owner -> representative pid (largest RSS seen for that owner)
    total_rss = 0
    unresolved_kb = 0

    for pid, node in tbl.items():
        rss = node["rss_kb"]
        total_rss += rss
        name, kind, _wd = owner_of(pid, tbl, sess)
        if kind == "?":
            unresolved_kb += rss
            continue
        by_owner[name] = by_owner.get(name, 0) + rss
        owner_kind[name] = kind
        if rss > owner_rss_pid.get(name, (0, 0))[1]:
            owner_rss_pid[name] = (pid, rss)

    # rig breakdown: free for sessions (work_dir from gc session list). For
    # daemons it costs one lsof call each — measured live at ~30ms/call, and
    # a real machine easily carries 400+ distinct daemon owner labels (root
    # system services included), which would mean 400+ lsof calls EVERY
    # cycle (measured: 13.5s wall/run, unacceptable for a 300s-interval
    # "cheap, read-only" sampler). Bounded to the top RIG_RESOLVE_TOP_N
    # daemon owners BY RSS — the long tail of small system daemons lands in
    # "unknown" without ever paying for lsof; they're too small to be an
    # actionable rig-cut candidate anyway, and by_owner (unbounded, free)
    # still reports their RSS honestly, just not broken out by rig.
    by_rig = {}
    if compute_rig:
        sess_workdir_by_name = {}
        for s in sess.values():
            sess_workdir_by_name[s["name"]] = s["work_dir"]

        daemon_owners_by_rss = sorted(
            (n for n, k in owner_kind.items() if k == "daemon"),
            key=lambda n: -by_owner[n],
        )
        rig_lookup_allowed = set(daemon_owners_by_rss[:RIG_RESOLVE_TOP_N])

        for name, rss in by_owner.items():
            wd = sess_workdir_by_name.get(name)
            if wd is None and owner_kind.get(name) == "daemon" and name in rig_lookup_allowed:
                pid = owner_rss_pid.get(name, (None, 0))[0]
                if pid:
                    wd = cwd_of_pid(pid)
            rig = resolve_rig(wd) or "unknown"
            by_rig[rig] = by_rig.get(rig, 0) + rss

    swap_used_mb, swap_total_mb = swap_usage()
    free_pct = mem_free_pct()

    return {
        "ts": now,
        "total_rss_kb": total_rss,
        "unresolved_kb": unresolved_kb,
        "n_procs": len(tbl),
        "swap_used_mb": swap_used_mb,
        "swap_total_mb": swap_total_mb,
        "free_pct": free_pct,
        "by_owner": by_owner,
        "owner_kind": owner_kind,
        "by_rig": by_rig,
        "sessions_lookup_failed": not sess_ok,
    }


def swap_usage():
    out = sh(["sysctl", "vm.swapusage"], timeout=10)
    m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M", out)
    if m:
        return float(m.group(2)), float(m.group(1))
    return None, None


def mem_free_pct():
    out = sh(["memory_pressure", "-Q"], timeout=6)
    m = re.search(r"free percentage:\s*(\d+)%", out)
    return int(m.group(1)) if m else None
