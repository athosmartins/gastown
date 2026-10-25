"""ga-qdtmq2 — claude-crew-account.py: the Mayor's and the crews' Claude account follows the pool decision, LIVE.

Every test runs against a FAKE `security` (a json store; it logs every argv so we can prove no secret rides on a command
line) and a loopback profile server. Nothing here touches the real Keychain or the network.

The harness PROVES that last sentence instead of trusting it (the Mayor's finding on this branch: the first version leaked into
production - `CLAUDE_CREW_NOTIFY` falls back to `shutil.which('notify')` and the log follows the caller's `GC_CITY_PATH`):
  * `_pin_env` (autouse, every test) points notify / security / the city / the state at sentinels and tmp paths, so even a test
    that forgets to build a `World` cannot reach the real ones;
  * `_nothing_real_was_touched` (autouse, once per session) records every WRITE this process makes to the real log / state / lock
    (an audit hook, so it names the test) and asserts at the end that there was none and that no sentinel was ever executed.
    It does not diff the files: the launchd job rewrites the real state file every 60 s (ga-615cgc). The hook does not see a CHILD
    process: the one test that spawns the script (the env -i one) proves only that the pinned paths were used, not that nothing else was;
  * `test_the_real_script_run_from_an_empty_environment...` runs the script as launchd would (env -i) under both interpreters.
"""
import contextlib
import copy
import fcntl
import http.server
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve()
SCRIPT = HERE.parents[1] / "packs" / "town-deltas" / "assets" / "scripts" / "claude-crew-account.py"
spec = importlib.util.spec_from_file_location("claude_crew_account_under_test", SCRIPT)
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)

FAKE_SECURITY = r'''#!/usr/bin/env python3
import json, os, re, sys
d = os.environ["FAKE_SEC_DIR"]
store_p = os.path.join(d, "store.json")
store = json.load(open(store_p)) if os.path.exists(store_p) else {}
with open(os.path.join(d, "argv.log"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a and a[0] == "-i":
    for line in sys.stdin.read().splitlines():
        m = re.match(r'add-generic-password -U -a "([^"]+)" -s "([^"]+)" -X ([0-9a-f]+)$', line.strip())
        if not m:
            sys.exit(3)
        if m.group(2) in os.environ.get("FAKE_SEC_WFAIL", "").split("|"):
            sys.exit(1)                                   # a write that fails loudly
        if m.group(2) in os.environ.get("FAKE_SEC_DROP", "").split("|"):
            continue                                      # accepted (exit 0) but never stored: only a read-back notices
        store[m.group(2)] = {"acct": m.group(1), "secret": bytes.fromhex(m.group(3)).decode()}
        with open(os.path.join(d, "writes.log"), "a") as f:
            f.write(m.group(2) + "\n")
    json.dump(store, open(store_p, "w"))
    sys.exit(0)
if a and a[0] == "find-generic-password":
    svc = a[a.index("-s") + 1]
    if svc in os.environ.get("FAKE_SEC_FAIL", "").split("|"):
        sys.exit(1)
    if svc not in store:
        sys.exit(44)
    if "-w" in a:
        print(store[svc]["secret"])
    else:
        print('keychain: "login.keychain-db"\n    "acct"<blob>="%s"\n    "svce"<blob>="%s"' % (store[svc]["acct"], svc))
    sys.exit(0)
sys.exit(2)
'''

FAKE_TMUX = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_TMUX_DIR"]
a = sys.argv[1:]
with open(os.path.join(d, "tmux.log"), "a") as f:
    f.write(json.dumps(a) + "\n")
if a[:1] == ["-L"]:
    a = a[2:]
if os.environ.get("FAKE_TMUX_DOWN"):
    sys.exit(1)
pp = os.path.join(d, "panes.json")
panes = json.load(open(pp)) if os.path.exists(pp) else {}
t = a[a.index("-t") + 1] if "-t" in a else None
p = panes.get(t)
if a[:1] == ["display-message"]:
    if p is None:
        sys.exit(1)
    print(p["pid"])
    sys.exit(0)
if a[:1] == ["capture-pane"]:
    if p is None:
        sys.exit(1)
    p["captures"] = p.get("captures", 0) + 1
    text = p["text"]
    if p.get("flip_after") is not None and p["captures"] > p["flip_after"]:
        text = p["flip_text"]
    json.dump(panes, open(pp, "w"))
    sys.stdout.write(text)
    sys.exit(0)
if a[:1] == ["send-keys"]:
    if p is None:
        sys.exit(1)
    with open(os.path.join(d, "keys.log"), "a") as f:
        f.write(t + " " + " ".join(a[a.index(t) + 1:]) + "\n")
    if p.get("escape_clears"):
        p["text"] = p["clear_text"]
    json.dump(panes, open(pp, "w"))
    sys.exit(0)
sys.exit(2)
'''

FAKE_GC = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_GC_DIR"]
a = sys.argv[1:]
with open(os.path.join(d, "gc.log"), "a") as f:
    f.write(json.dumps(a) + "\n")
if a[:1] == ["--city"]:
    a = a[2:]
if a[:2] == ["session", "list"]:
    if os.environ.get("FAKE_GC_LIST_FAIL"):
        sys.exit(1)
    p = os.path.join(d, "sessions.json")
    sys.stdout.write(open(p).read() if os.path.exists(p) else '{"ok": true, "schema_version": "1", "sessions": []}')
    sys.exit(0)
if a[:2] == ["session", "reset"]:
    if os.environ.get("FAKE_GC_RESET_FAIL"):
        sys.stderr.write("boom\n")
        sys.exit(1)
    sys.exit(0)
sys.exit(2)
'''

NOTIFY = "#!/bin/sh\necho \"$@\" >> \"$FAKE_SEC_DIR/notify.log\"\n[ -n \"$FAKE_NOTIFY_FAIL\" ] && exit 7\nexit 0\n"
EMAIL = {"crypto": "athoscrypto@gmail.com", "amb": "throw.away.amb@gmail.com", "b85": "athosb85@gmail.com",
         "terr": "terrenos.incorporacoes@gmail.com", "martins": "athosmartins@gmail.com"}


T0 = time.time()      # one clock for every login in a test: only `rexp_days` tells two logins of the same age apart


def blob(tag, *, refresh=True, rexp_days=29.0, scopes=None, acc_hours=7.0, rt=None):
    now = T0
    o = {"accessToken": f"sk-ant-oat01-{tag}-acc", "expiresAt": int((now + acc_hours * 3600) * 1000),
         "scopes": scopes if scopes is not None else ["user:inference", "user:profile", "user:sessions:claude_code"],
         "subscriptionType": "max"}
    if refresh:
        o["refreshToken"] = f"sk-ant-ort01-{rt or tag}-ref"
        if rexp_days is not None:
            o["refreshTokenExpiresAt"] = int((now + rexp_days * 86400) * 1000)
    return {"claudeAiOauth": o}


# ── the harness cannot leak ────────────────────────────────────────────────────
_REAL_ENV = dict(os.environ)             # what the process looked like BEFORE any test pinned anything
_GUARD: dict = {}


def _sentinel(path: Path, hits: Path) -> None:
    path.write_text(f'#!/bin/sh\necho "$0 $*" >> "{hits}"\nexit 99\n')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def _real_files():
    # The pool's decision file (crew.DEFAULT_DECISION) is the pool daemon's and is not watched. The state file is the script's own,
    # and the launchd job rewrites it - and logs, and takes the lock - on its own schedule, so these are watched for writes made
    # BY THIS PROCESS (see _watching), never compared before/after.
    cities = {c for c in (_REAL_ENV.get("GC_CITY_PATH"), str(Path.home() / "gt" / ".gascity-gastown-hq")) if c}
    out = [Path(crew.DEFAULT_STATE)]
    for c in sorted(cities):
        out += [Path(c) / ".gc" / "logs" / "claude-crew-account.log", Path(c) / ".gc" / "claude-crew-account.lock"]
    return out


# ga-615cgc: the guard used to snapshot (size, mtime) of the real files and compare at the end of the session. The live job is a
# separate process that rewrites the real state file every 60 s, so every run longer than one tick failed at teardown (pytest
# exit 1 with every test green), and the log changes whenever the job acts: "the file changed" was read as "a test touched it".
# An audit hook answers the question that was actually asked - did THIS process write it - and cannot be tripped by another process.
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC
_WATCH: dict = {"paths": frozenset(), "hits": None}


def _canon(p):
    try:
        return os.path.realpath(os.fsdecode(p))
    except (TypeError, ValueError):
        return None                                   # an fd, or anything that is not a path: not ours to judge


def _is_write(mode, flags):
    if isinstance(flags, int):
        return bool(flags & _WRITE_FLAGS)
    return not isinstance(mode, str) or any(c in mode for c in "wax+")      # told nothing usable: assume the worst, never "a read"


def _audit(event, args):
    hits = _WATCH["hits"]
    if hits is None:
        return
    if event == "open":
        if not _is_write(args[1], args[2]):
            return                                    # reading a real file is not touching it
        paths = (args[0],)
    elif event == "os.rename":
        paths = args[:2]
    elif event in ("os.remove", "os.truncate", "os.utime"):          # utime: the old mtime guard saw a test faking a tick, so this one must
        paths = args[:1]
    else:
        return
    for p in paths:
        if _canon(p) in _WATCH["paths"]:
            hits.append(f"{event} {os.fsdecode(p)}  [during {os.environ.get('PYTEST_CURRENT_TEST', 'collection or a fixture')}]")


sys.addaudithook(_audit)                              # a hook cannot be removed: it does nothing unless _watching is active


@contextlib.contextmanager
def _watching(paths):
    """Yield the list that collects every write this process makes to `paths` while the block runs."""
    canon = [_canon(p) for p in paths]
    if not canon or not all(canon):
        raise ValueError(f"cannot watch {list(paths)!r}: a path that cannot be resolved would be silently left unwatched")
    before, hits = dict(_WATCH), []
    _WATCH.update(paths=frozenset(canon), hits=hits)
    try:
        yield hits
    finally:
        _WATCH.update(before)


@pytest.fixture(scope="session", autouse=True)
def _nothing_real_was_touched(tmp_path_factory):
    guard = tmp_path_factory.mktemp("guard")
    (guard / "bin").mkdir()
    hits = guard / "hits.log"
    _sentinel(guard / "notify", hits)
    _sentinel(guard / "security", hits)
    _sentinel(guard / "bin" / "notify", hits)
    _sentinel(guard / "bin" / "security", hits)
    _sentinel(guard / "tmux", hits)
    _sentinel(guard / "bin" / "tmux", hits)
    _sentinel(guard / "gc", hits)
    _sentinel(guard / "bin" / "gc", hits)
    _GUARD.update(dir=guard, hits=hits)
    with _watching(_real_files()) as touched:
        yield
    assert not hits.exists(), "a test reached the REAL notify/security/tmux/gc (sentinel executed):\n" + hits.read_text()
    assert not touched, "a test touched the REAL claude-crew-account log/state/lock:\n" + "\n".join(touched)


@pytest.fixture(autouse=True)
def _pin_env(monkeypatch, tmp_path):
    g = _GUARD["dir"]
    for k, v in {"CLAUDE_CREW_NOTIFY": g / "notify", "CLAUDE_CREW_SECURITY": g / "security", "CLAUDE_CREW_TMUX": g / "tmux", "CLAUDE_CREW_GC": g / "gc",
                 "GC_CITY_PATH": tmp_path / "pinned-city", "CLAUDE_CREW_STATE": tmp_path / "pinned-state.json",
                 "CLAUDE_CREW_DECISION": tmp_path / "pinned-decision.json", "CLAUDE_CREW_SESSIONS_DIR": tmp_path / "pinned-sessions",
                 "CLAUDE_CREW_ACCOUNTS_DIR": tmp_path / "pinned-accts", "HOME": tmp_path / "pinned-home"}.items():
        monkeypatch.setenv(k, str(v))
    monkeypatch.setenv("PATH", f"{g / 'bin'}:/usr/bin:/bin")        # `which notify` / bare `security` find a sentinel, never the real one


LIVE_TICK = ("import os, sys, pathlib\n"              # what publish_state() does, from ANOTHER process: tmp file, then os.replace over the state
             "p = pathlib.Path(sys.argv[1]); t = p.with_name(p.name + '.tmp.1')\n"
             "t.write_text('{\"updated\": \"2026-10-08T09:22:08Z\"}\\n'); os.replace(t, p)\n")


def test_a_rewrite_by_the_live_job_is_not_a_test_touching_the_real_files(tmp_path):
    live = tmp_path / "claude_crew_current_account.json"
    live.write_text('{"updated": "2026-10-08T09:21:08Z"}\n')
    with _watching([live]) as touched:
        subprocess.run([sys.executable, "-c", LIVE_TICK, str(live)], check=True)
        subprocess.run([sys.executable, "-c", LIVE_TICK, str(live)], check=True)
    assert "09:22:08Z" in live.read_text()                  # the live job really did rewrite it: the empty verdict below is not vacuous
    assert touched == []


def _w_text(p, other):
    p.write_text("x")


def _w_append(p, other):
    with open(p, "a") as f:
        f.write("x")


def _w_read_write(p, other):
    with open(p, "r+") as f:
        f.write("x")


def _w_os_open(p, other):
    os.close(os.open(p, os.O_WRONLY))


def _w_replace_over(p, other):
    os.replace(other, p)


def _w_rename_away(p, other):
    os.rename(p, other)


def _w_remove(p, other):
    os.remove(p)


def _w_truncate(p, other):
    os.truncate(p, 0)


def _w_utime(p, other):
    os.utime(p, (0, 0))


def _w_through_a_symlink(p, other):
    other.symlink_to(p)
    other.write_text("x")


@pytest.mark.parametrize("write", [_w_text, _w_append, _w_read_write, _w_os_open, _w_replace_over, _w_rename_away, _w_remove, _w_truncate, _w_utime,
                                   _w_through_a_symlink], ids=lambda f: f.__name__[3:])
def test_a_write_by_a_test_to_a_real_file_is_caught_and_names_the_test(tmp_path, write):
    live, other = tmp_path / "state.json", tmp_path / "other"
    live.write_text("{}")
    if write is _w_replace_over:
        other.write_text("{}")
    with _watching([live]) as touched:
        write(live, other)
    assert len(touched) == 1 and "test_a_write_by_a_test_to_a_real_file_is_caught_and_names_the_test" in touched[0], touched


@pytest.mark.parametrize("mode, flags, is_write", [
    ("rb", os.O_RDONLY | os.O_CLOEXEC, False), ("wb", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, True), (None, os.O_RDWR, True),
    (None, os.O_RDONLY, False), ("ab", os.O_WRONLY | os.O_APPEND, True),
    ("r+", None, True), ("a", None, True), ("x", None, True), ("rb", None, False),          # no flags: the mode decides
    (None, None, True),                                                                      # nothing to go by: a write, never a read
])
def test_what_counts_as_a_write_to_a_real_file(mode, flags, is_write):
    assert _is_write(mode, flags) is is_write


def test_reading_a_real_file_is_not_touching_it(tmp_path):
    live = tmp_path / "state.json"
    live.write_text("{}")
    with _watching([live]) as touched:
        live.read_text(), live.read_bytes(), live.stat(), open(live, "rb").close()
    assert touched == []


@pytest.mark.parametrize("paths", [[], [3], ["a-path", 3]], ids=["nothing", "an-fd", "one-good-one-unresolvable"])
def test_watching_nothing_or_something_unresolvable_is_refused_not_left_silently_empty(paths):
    active = dict(_WATCH)                                 # the session guard is live around this test: a refusal must not disturb it
    with pytest.raises(ValueError):
        with _watching(paths):
            pass
    assert _WATCH == active


class World:
    def __init__(self, tmp, monkeypatch):
        self.d = tmp / "world"
        self.d.mkdir()
        self.tokens = {}                                    # access token -> e-mail, what the profile server answers
        self.profile_status = 200
        w = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
                email = w.tokens.get(tok)
                if w.profile_status != 200 or not email:
                    self.send_response(w.profile_status if w.profile_status != 200 else 401)
                    self.end_headers()
                    return
                body = json.dumps({"account": {"email": email}, "organization": {"name": "x"}}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        (self.d / "tmuxd").mkdir()
        (self.d / "gcd").mkdir()
        for name, body in (("security", FAKE_SECURITY), ("notify", NOTIFY), ("tmux", FAKE_TMUX), ("gc", FAKE_GC)):
            p = self.d / name
            p.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))   # not the PATH's python: PATH is pinned to the sentinels
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.d / "city" / ".gc" / "logs").mkdir(parents=True)
        (self.d / "sessions").mkdir()
        self.now = time.time()
        for k, v in {
            "FAKE_SEC_DIR": str(self.d), "CLAUDE_CREW_SECURITY": str(self.d / "security"),
            "FAKE_TMUX_DIR": str(self.d / "tmuxd"), "CLAUDE_CREW_TMUX": str(self.d / "tmux"),
            "FAKE_GC_DIR": str(self.d / "gcd"), "CLAUDE_CREW_GC": str(self.d / "gc"),
            "CLAUDE_CREW_NOTIFY": str(self.d / "notify"), "CLAUDE_CREW_STATE": str(self.d / "crew_state.json"),
            "CLAUDE_CREW_DECISION": str(self.d / "pool_decision.json"), "CLAUDE_CREW_SESSIONS_DIR": str(self.d / "sessions"),
            "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
            "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(self.now),
        }.items():
            monkeypatch.setenv(k, v)
        for k in ("GC_CREW_ACCOUNT", "CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL", "FAKE_SEC_WFAIL", "FAKE_SEC_DROP", "FAKE_NOTIFY_FAIL",
                  "GC_CREW_UNSTICK", "FAKE_TMUX_DOWN", "CLAUDE_CREW_TMUX_SOCKET", "GC_CREW_RESET", "FAKE_GC_LIST_FAIL", "FAKE_GC_RESET_FAIL"):
            monkeypatch.delenv(k, raising=False)
        self.mp = monkeypatch
        # the world must be sealed: every seam inside this tmp dir, none of them a sentinel
        for fn in (crew.security_bin, crew.state_path, crew.decision_path, crew.sessions_dir, crew.tmux_bin):
            assert str(fn()).startswith(str(self.d)), f"{fn.__name__} escapes the test world: {fn()}"
        assert os.environ["CLAUDE_CREW_NOTIFY"].startswith(str(self.d)) and str(crew.city()).startswith(str(self.d))

    # keychain
    def store(self):
        p = self.d / "store.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def put(self, service, b, acct="athos"):
        s = self.store()
        s[service] = {"acct": acct, "secret": json.dumps(b)}
        (self.d / "store.json").write_text(json.dumps(s))

    def get(self, service):
        v = self.store().get(service)
        return json.loads(v["secret"]) if v else None

    def writes(self):
        p = self.d / "writes.log"
        return p.read_text().splitlines() if p.exists() else []

    def argv_log(self):
        p = self.d / "argv.log"
        return p.read_text() if p.exists() else ""

    def notified(self):
        p = self.d / "notify.log"
        return p.read_text().splitlines() if p.exists() else []

    def src_service(self, key):
        return crew.source_services(EMAIL[key])[0]

    def account(self, key, b, *, fresh=False):
        """An account's own stored login. PRODUCTION shape by default: a stored copy's access token has been expired for
        22-41 h (measured by the reviewer), so the profile CANNOT say whose it is. `fresh=True` is the unrealistic case in
        which the profile answers for it."""
        b = copy.deepcopy(b)
        if fresh:
            self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[key]
        else:
            b["claudeAiOauth"]["expiresAt"] = int((T0 - 30 * 3600) * 1000)
        self.put(self.src_service(key), b)

    def default(self, key, b):
        self.put(crew.DEFAULT_SERVICE, b)
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[key]

    def decide(self, key, exhausted=None, age_s=5):
        d = {"current": EMAIL[key], "updated": crew._iso(self.now - age_s), "schema": 1,
             "exhausted": {EMAIL[k]: {"reset_epoch": self.now + 86400, "claim": "seven_day"} for k in (exhausted or [])}}
        (self.d / "pool_decision.json").write_text(json.dumps(d))

    def run(self, dry=False, at=None):
        if at is not None:
            self.mp.setenv("CLAUDE_CREW_NOW", str(at))
        return crew.run_once(dry)

    def state(self):
        p = self.d / "crew_state.json"
        return json.loads(p.read_text()) if p.exists() else {}

    # tmux (ga-ci3uao): a pane is {pid, text, ...}; the fake logs every argv and every key it is asked to send
    def pane(self, pane_id, pid, text, **kw):
        p = self.d / "tmuxd" / "panes.json"
        panes = json.loads(p.read_text()) if p.exists() else {}
        panes[pane_id] = {"pid": pid, "text": text, **kw}
        p.write_text(json.dumps(panes))

    def pane_set(self, pane_id, **kw):
        p = self.d / "tmuxd" / "panes.json"
        panes = json.loads(p.read_text())
        panes[pane_id].update(kw)
        p.write_text(json.dumps(panes))

    def keys(self):
        p = self.d / "tmuxd" / "keys.log"
        return p.read_text().splitlines() if p.exists() else []

    def tmux_calls(self):
        p = self.d / "tmuxd" / "tmux.log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    # gc (ga-yqzedv): the fake logs every argv; `session list --json` answers from sessions.json
    def gc_sessions(self, *pairs):
        rows = [{"id": i, "alias": n, "session_name": n, "state": "active"} for i, n in pairs]
        (self.d / "gcd" / "sessions.json").write_text(json.dumps({"ok": True, "schema_version": "1", "sessions": rows}))

    def gc_calls(self):
        p = self.d / "gcd" / "gc.log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def log(self):
        p = self.d / "city" / ".gc" / "logs" / "claude-crew-account.log"
        return p.read_text() if p.exists() else ""


@pytest.fixture
def w(tmp_path, monkeypatch):
    world = World(tmp_path, monkeypatch)
    yield world
    world.srv.shutdown()


def secrets_in(text, w):
    return [t for t in ("sk-ant-oat01", "sk-ant-ort01") if t in text]


# ── 0. the item names ───────────────────────────────────────────────────────
def test_item_names_are_derived_from_the_absolute_path_and_match_the_measured_ones():
    # measured 06/10 (ga-yyltfk README + recomputation): the 05/10 note had two of these swapped.
    base = "/Users/athos/.gastown/claude-accounts/"
    assert crew.dir_service(base + "athoscrypto") == "Claude Code-credentials-1b9e5c89"
    assert crew.dir_service(base + "throw.away.amb") == "Claude Code-credentials-d0aeaa6c"
    assert crew.dir_service(base + "athosb85") == "Claude Code-credentials-3839ec1f"
    assert crew.dir_service("/Users/athos/.gastown/claude-pool-cred") == "Claude Code-credentials-50adeaf1"


# ── 1. in sync: nothing is written ───────────────────────────────────────────
def test_in_sync_writes_nothing(w):
    b = blob("crypto")
    w.default("crypto", b)
    w.account("crypto", b)
    w.decide("crypto")
    assert w.run() == 0
    assert w.writes() == []
    assert w.state()["current"] == EMAIL["crypto"]


# ── 2. follow the pool: the live switch ───────────────────────────────────────
def test_follows_the_pool_decision_and_syncs_the_leaving_account_back(w):
    cur = blob("crypto", rt="crypto-rotated")                    # the default item: crypto, its refresh rotated since login
    w.default("crypto", cur)
    w.account("crypto", blob("crypto", rt="crypto-old"))         # its own stored copy is behind
    amb = blob("amb")
    w.account("amb", amb)
    w.decide("amb")
    w.run()
    now_default = w.get(crew.DEFAULT_SERVICE)
    assert now_default["claudeAiOauth"]["refreshToken"] == amb["claudeAiOauth"]["refreshToken"]
    # the leaving account's login was copied back BEFORE the default item was overwritten (a refresh token lives in one place)
    assert w.get(w.src_service("crypto"))["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-crypto-rotated-ref"
    assert w.writes() == [w.src_service("crypto"), crew.DEFAULT_SERVICE]
    s = w.state()
    assert s["current"] == EMAIL["amb"] and s["last_switch"]["from"] == EMAIL["crypto"]
    assert "SWITCH crews" in w.log()


def test_no_secret_ever_in_argv_log_state_or_notification(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    w.account("b85", blob("b85", refresh=False))                  # a setup-token source: forces an alert too
    w.decide("b85")
    w.run()
    for text in (w.argv_log(), w.log(), json.dumps(w.state()), "\n".join(w.notified())):
        assert secrets_in(text, w) == []
    assert all(json.loads(l)[:1] in (["-i"], ["find-generic-password"]) for l in w.argv_log().splitlines())
    assert not any("-X" in json.loads(l) for l in w.argv_log().splitlines())   # the hex never rides on a command line


# ── 3. never overwrite on a guess ───────────────────────────────────────────
def test_profile_unanswered_means_nothing_is_touched(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.profile_status = 500
    w.run()
    assert w.writes() == []
    assert w.get(crew.DEFAULT_SERVICE)["claudeAiOauth"]["accessToken"].startswith("sk-ant-oat01-crypto")


def test_keychain_unreadable_means_nothing_is_touched(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.mp.setenv("FAKE_SEC_FAIL", crew.DEFAULT_SERVICE)
    w.run()
    assert w.writes() == []
    assert w.notified() == []                                     # a locked/crashed `security` is "could not tell", not a page
    assert "NOT touched and NOT healed" in w.log()                # but the log says what it did not do


def test_a_missing_default_item_is_alerted_once_not_skipped_as_nothing_to_do(w):
    w.account("amb", blob("amb"))                                 # healable sources exist, the default item does not
    w.decide("amb")
    w.run()
    assert w.writes() == []                                       # absent owner is unknowable: nothing is created
    missing = [n for n in w.notified() if "default item does not exist" in n]
    assert len(missing) == 1 and "job falhou" in missing[0]
    w.run(at=w.now + 60)
    assert len([n for n in w.notified() if "default item does not exist" in n]) == 1   # one push per alert window


def test_a_source_that_belongs_to_someone_else_is_refused_when_the_profile_can_say_so(w):
    """The UNREALISTIC case (a fresh access token the profile answers for). The production case is further down."""
    w.default("crypto", blob("crypto"))
    b = blob("amb")
    w.put(w.src_service("amb"), b)
    w.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL["b85"]   # the dir item holds ANOTHER account's login
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert "belongs to" in w.log()


# ── 4. a setup-token is never written to the default item ─────────────────────
def test_wanted_account_without_a_full_login_holds_and_names_the_missing_login(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb", refresh=False))                  # setup-token only
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert w.state()["current"] == EMAIL["crypto"]
    assert len(w.notified()) == 1 and "job falhou" in w.notified()[0] and EMAIL["amb"] in w.notified()[0]
    w.run()                                                       # the same problem a minute later: no second push
    assert len(w.notified()) == 1


def test_a_login_about_to_expire_is_not_a_source(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb", rexp_days=0.5))
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()


def test_no_scope_for_sessions_is_not_a_full_login(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb", scopes=["user:inference"]))
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()


# ── 5. exhausted: fall to the next account that HAS a login ───────────────────
def test_exhausted_current_account_and_wanted_without_login_falls_to_the_next(w):
    w.default("crypto", blob("crypto"))
    w.account("crypto", blob("crypto"))
    w.account("b85", blob("b85"))                                 # has a full login
    w.decide("terr", exhausted=["crypto"])                        # the pool is on terrenos: no login for it
    w.run()
    assert w.state()["current"] == EMAIL["b85"] and w.state()["last_switch"]["reason"] == "fallback"
    assert any("fall to" in n for n in w.notified())


def test_stuck_when_nobody_has_a_login(w):
    w.default("crypto", blob("crypto"))
    w.decide("terr", exhausted=["crypto"])
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert any("STUCK" in n for n in w.notified())


def test_a_current_account_with_balance_is_not_left_just_because_the_pool_moved(w):
    w.default("crypto", blob("crypto"))
    w.account("crypto", blob("crypto"))
    w.account("b85", blob("b85"))                                 # somewhere to go: leaving would be possible, and wrong
    w.decide("terr")                                              # pool on terrenos (no login); crypto still has balance
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()


# ── 6. the default item holds no full login at all: heal ──────────────────────
def test_default_item_holding_a_setup_token_is_healed_from_the_wanted_account(w):
    w.put(crew.DEFAULT_SERVICE, blob("old", refresh=False))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert w.get(crew.DEFAULT_SERVICE)["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-amb-ref"
    assert any("Remote Control is broken" in n for n in w.notified())


# ── 7. sync-back never regresses a login ──────────────────────────────────────
def test_sync_back_does_not_overwrite_a_newer_login(w):
    w.default("crypto", blob("crypto", rt="old-login", rexp_days=10))
    w.account("crypto", blob("crypto", rt="new-login", rexp_days=29))   # redone later: its refresh token lives longer
    w.decide("crypto")
    w.run()
    assert w.writes() == []
    assert w.get(w.src_service("crypto"))["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-new-login-ref"


def test_an_account_without_its_own_item_gets_a_reserve_before_it_is_overwritten(w):
    w.default("terr", blob("terr"))                               # terrenos' login lives ONLY in the default item
    w.account("crypto", blob("crypto"))
    w.decide("crypto")
    w.run()
    reserve = crew.reserve_service(EMAIL["terr"])
    assert w.get(reserve)["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-terr-ref"
    assert w.writes().index(reserve) < w.writes().index(crew.DEFAULT_SERVICE)
    # and it is a source afterwards: terrenos can come back with Remote Control
    w.decide("terr", exhausted=["crypto"])
    w.run()
    assert w.get(crew.DEFAULT_SERVICE)["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-terr-ref"


# ── 8. the fence ───────────────────────────────────────────────────────────
def test_fence_refuses_everything_that_is_not_allowlisted(w):
    pool = crew.dir_service(crew.POOL_CRED_DIR)
    for svc in (pool, "Claude Code-credentials-deadbeef", "Claude Code-credentials-1b9e5c89\" -X 00", "something else"):
        assert crew.kc_write(svc, "athos", blob("x")) is False
    assert crew.kc_write(crew.DEFAULT_SERVICE, 'athos" ; delete', blob("x")) is False
    assert w.writes() == []


def test_the_pool_item_is_excluded_even_if_an_account_is_pointed_at_it(w):
    w.mp.setenv("CLAUDE_CREW_ACCOUNTS", json.dumps({"x@y.z": {"dir": crew.POOL_CRED_DIR}}))
    assert crew.dir_service(crew.POOL_CRED_DIR) in crew.source_services("x@y.z")
    assert crew.dir_service(crew.POOL_CRED_DIR) not in crew.writable_services()


# ── 9. the decision ────────────────────────────────────────────────────────
def test_an_old_but_unchanged_decision_is_followed(w):
    """The pool's `updated` moves only when the pool changes account (75 min old while the daemon ran every minute): age is
    not a liveness signal. A 3-hour-old decision that differs from where the crews are IS followed."""
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb", age_s=3 * 3600)
    w.run()
    assert w.state()["current"] == EMAIL["amb"] and w.notified() == []


def test_no_decision_holds(w):
    w.default("crypto", blob("crypto"))
    w.run()
    assert w.writes() == []


def test_kill_switches(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.mp.setenv("GC_CREW_ACCOUNT", "0")
    w.run()
    assert w.writes() == []
    w.mp.delenv("GC_CREW_ACCOUNT")
    (w.d / "city" / ".gc" / "no-crew-account").write_text("")
    w.run()
    assert w.writes() == []


def test_dry_run_writes_nothing_notifies_nobody_and_leaves_the_real_log_alone(w):
    w.default("crypto", blob("crypto"))
    w.account("b85", blob("b85", refresh=False))                  # a problem that WOULD alert in a real run
    w.decide("b85")
    try:
        w.run(dry=True)
    finally:
        crew.DRY = False
    assert w.writes() == [] and w.notified() == []
    assert w.log() == ""                                          # nothing in the city log: dry-run talks to stderr
    assert not (w.d / "crew_state.json").exists()


# ── 10. Remote Control is verified after a switch ─────────────────────────────
def _session(w, pid, bridge):
    d = {"pid": pid, "status": "idle", "sessionId": f"s{pid}"}
    if bridge:
        d["bridgeSessionId"] = bridge
    (w.d / "sessions" / f"{pid}.json").write_text(json.dumps(d))


def test_remote_control_bridges_are_checked_a_minute_after_the_switch(w):
    me, parent = os.getpid(), os.getppid()
    _session(w, me, "cse_a")
    _session(w, parent, "cse_b")
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert set(w.state()["pending_verify"]["pids"]) == {str(me), str(parent)}
    w.run(at=w.now + 90)                                          # both bridges still there: all good, the check clears
    assert "pending_verify" not in w.state() and "rc_lost" not in w.state()
    assert "all 2 Remote Control bridges are still up" in w.log()


def test_a_bridge_lost_after_the_switch_is_reported(w):
    me, parent = os.getpid(), os.getppid()
    _session(w, me, "cse_a")
    _session(w, parent, "cse_b")
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    _session(w, parent, None)                                     # this one lost its bridge
    w.run(at=w.now + 90)
    assert w.state()["rc_lost"]["pids"] == [parent]
    assert any("lost Remote Control" in n for n in w.notified())


def test_not_yet_a_minute_does_not_judge(w):
    _session(w, os.getpid(), "cse_a")
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    _session(w, os.getpid(), None)
    w.run(at=w.now + 20)
    assert "pending_verify" in w.state() and w.notified() == []


# ══ gate fix (ga-qdtmq2, verdict on 581c67bb) ════════════════════════════════════════════════════════════════════
def _own(w, key):
    return w.src_service(key)


def _rt(b):
    return b["claudeAiOauth"]["refreshToken"]


def _switch_crypto_to_amb(w, **kw):
    """The production-shaped switch: the stored copies' access tokens are expired, so the profile cannot vouch for them."""
    w.default("crypto", blob("crypto", rt="crypto-rotated"))
    w.account("crypto", blob("crypto", rt="crypto-old"))
    w.account("amb", blob("amb"), **kw)
    w.decide("amb")
    return w.run()


# ── P2 / P3: a sync-back that failed or could not tell must STOP the overwrite ─────────────────────────────────
def _break_sync_back(w, mode):
    own = _own(w, "crypto")
    if mode == "read":                                            # P2: the leaving account's own item cannot be read
        w.mp.setenv("FAKE_SEC_FAIL", own)
    elif mode == "wfail":                                         # `security` refuses the write
        w.mp.setenv("FAKE_SEC_WFAIL", own)
    elif mode == "drop":                                          # `security` says yes and stores nothing: only a read-back sees it
        w.mp.setenv("FAKE_SEC_DROP", own)
    else:                                                         # P3: verified_write forced False for the own item
        real = crew.verified_write
        w.mp.setattr(crew, "verified_write", lambda svc, acct, b: False if svc == own else real(svc, acct, b))


@pytest.mark.parametrize("mode", ["read", "wfail", "drop", "forced-false"])
def test_a_sync_back_that_failed_or_could_not_tell_keeps_the_only_copy_of_the_rotated_token(w, mode):
    w.default("crypto", blob("crypto", rt="crypto-rotated"))      # the ONLY place the rotated refresh token exists
    w.account("crypto", blob("crypto", rt="crypto-old"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    _break_sync_back(w, mode)
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()                 # reviewer's symptom: writes == [DEFAULT], 0 pushes
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-crypto-rotated-ref"
    pushed = [n for n in w.notified() if "job falhou" in n]
    assert len(pushed) == 1 and EMAIL["crypto"] in pushed[0] and "sync-back" in pushed[0]
    w.run(at=w.now + 60)                                          # the same fault a minute later: still refused, no second push
    assert crew.DEFAULT_SERVICE not in w.writes() and len(w.notified()) == 1


def test_once_the_fault_clears_the_login_is_saved_and_only_then_the_switch_happens(w):
    w.default("crypto", blob("crypto", rt="crypto-rotated"))
    w.account("crypto", blob("crypto", rt="crypto-old"))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.mp.setenv("FAKE_SEC_FAIL", _own(w, "crypto"))
    w.run()
    w.mp.delenv("FAKE_SEC_FAIL")
    w.run(at=w.now + 60)
    assert w.writes() == [_own(w, "crypto"), crew.DEFAULT_SERVICE]
    assert _rt(w.get(_own(w, "crypto"))) == "sk-ant-ort01-crypto-rotated-ref"
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-ref"


def test_two_logins_that_cannot_be_compared_are_never_overwritten_blind(w):
    w.default("crypto", blob("crypto", rt="crypto-rotated"))                       # carries a refresh expiry
    w.account("crypto", blob("crypto", rt="crypto-old", rexp_days=None))           # does not: which one is newer is unknowable
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert any("sync-back" in n and EMAIL["crypto"] in n for n in w.notified())


# ── gate round 3 (ga-hqhbi6): "which login is newer" with NO refresh expiry on EITHER side is unknown, not "the default" ─
def test_two_logins_that_both_lack_a_refresh_expiry_are_never_overwritten_blind(w):
    w.default("crypto", blob("crypto", rt="live-lineage", rexp_days=None))
    w.account("crypto", blob("crypto", rt="human-relogin", rexp_days=None))      # a fresh human re-login, same shape
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert w.writes() == []                                       # neither the own item nor the default item was touched
    assert _rt(w.get(_own(w, "crypto"))) == "sk-ant-ort01-human-relogin-ref"
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-live-lineage-ref"
    assert any("sync-back" in n and EMAIL["crypto"] in n for n in w.notified())
    assert "neither of them carries a refresh expiry" in w.log()  # said, not silent: the log names the unknown


def test_the_same_login_on_both_sides_needs_no_recency_at_all(w):
    w.default("crypto", blob("crypto", rt="same", rexp_days=None))
    w.account("crypto", blob("crypto", rt="same", rexp_days=None))
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-ref"            # nothing to compare, nothing to veto
    assert not any("sync-back" in n for n in w.notified())


def test_a_stored_copy_that_is_not_a_full_login_is_replaced_not_protected(w):
    w.default("crypto", blob("crypto", rt="crypto-rotated"))                    # a full login, with a refresh expiry
    w.account("crypto", blob("crypto", refresh=False))                          # the own item holds a setup-token
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert w.get(_own(w, "crypto"))["claudeAiOauth"].get("refreshToken") == "sk-ant-ort01-crypto-rotated-ref"   # saved over it
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-ref"           # and the switch goes ahead
    assert not any("sync-back" in n for n in w.notified())


def test_the_overwrite_is_allowed_when_the_leaving_login_is_not_a_full_login_anyway(w):
    w.default("crypto", blob("crypto", refresh=False))            # a setup-token: nothing worth saving
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.mp.setenv("FAKE_SEC_FAIL", _own(w, "crypto"))               # even with its own item unreadable
    w.run()
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-ref"


# ── P4: the owner guard in the PRODUCTION shape (expired stored token => the profile cannot answer) ───────────────────
def test_production_path_an_expired_source_switches_but_says_the_owner_is_unverified_and_counts_it(w):
    _switch_crypto_to_amb(w)
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-ref"
    assert "owner unverified" in w.log()
    s = w.state()
    assert s["unverified_switches"] == 1
    assert s["identity"]["via"] == "switch-unverified" and s["unverified"]["email"] == EMAIL["amb"]
    assert secrets_in(json.dumps(s) + w.log(), w) == []


def test_an_unverified_identity_is_trusted_for_the_ttl_and_not_forever(w):
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 120)                                         # inside the TTL: the claimed identity still stands
    assert "cannot tell whose login" not in w.log() and w.state()["current"] == EMAIL["amb"]
    w.run(at=w.now + crew.IDENTITY_TTL_S + 120)                   # past it, the profile still silent: hold, do not assume
    assert "cannot tell whose login" in w.log()
    assert "still unverified" in w.log() and "unverified" not in w.state()      # gave up verifying, said so, stopped carrying it


def test_after_the_cli_refreshes_the_source_the_owner_is_checked_and_a_match_is_logged(w):
    _switch_crypto_to_amb(w)
    w.default("amb", blob("amb-refreshed", rt="amb-rotated"))     # the CLI refreshed it: new tokens, the profile answers
    w.run(at=w.now + 70)
    assert "owner verified" in w.log()
    s = w.state()
    assert "unverified" not in s and s["unverified_last"]["result"] == "verified" and s["identity"]["via"] == "profile"
    assert [x for x in w.writes() if x == crew.DEFAULT_SERVICE] == [crew.DEFAULT_SERVICE]


def test_after_the_cli_refreshes_a_source_that_was_someone_elses_it_is_alerted_quarantined_and_not_written_again(w):
    _switch_crypto_to_amb(w)                                      # amb's dir item actually holds b85's login (nobody could tell)
    w.default("b85", blob("b85-refreshed", rt="b85-rotated"))     # ...and the profile says so as soon as the CLI refreshed it
    for i in range(1, 5):
        w.run(at=w.now + 70 * i)
    pushed = [n for n in w.notified() if "turned out to belong to" in n]
    assert len(pushed) == 1 and EMAIL["amb"] in pushed[0] and EMAIL["b85"] in pushed[0] and _own(w, "amb") in pushed[0]
    assert w.writes().count(crew.DEFAULT_SERVICE) == 1            # no second write of the dead, already-rotated login
    assert w.state()["bad_sources"][_own(w, "amb")]["owner"] == EMAIL["b85"]
    assert w.state()["unverified_last"]["result"] == "mismatch"


def test_a_quarantined_source_comes_back_when_it_is_logged_in_again(w):
    _switch_crypto_to_amb(w)
    w.default("b85", blob("b85-refreshed", rt="b85-rotated"))
    w.run(at=w.now + 70)
    assert _own(w, "amb") in w.state()["bad_sources"]
    w.account("amb", blob("amb", rt="amb-relogin"))               # a human redid it: a NEW refresh token, not the quarantined one
    w.run(at=w.now + 140)
    assert w.writes().count(crew.DEFAULT_SERVICE) == 2 and _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-amb-relogin-ref"


# ── alerts: "told" means delivered ─────────────────────────────────────────────────────────────────────────────────
def _no_login_problem(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb", refresh=False))
    w.decide("amb")


def test_a_push_that_failed_is_not_recorded_as_told_and_is_retried(w):
    _no_login_problem(w)
    w.mp.setenv("FAKE_NOTIFY_FAIL", "1")
    w.run()
    assert len(w.notified()) == 1 and "notify exit=7" in w.log()
    w.mp.delenv("FAKE_NOTIFY_FAIL")
    w.run(at=w.now + 60)                                          # too soon to hammer a broken notify
    assert len(w.notified()) == 1
    w.run(at=w.now + 600)                                         # retried, delivered
    assert len(w.notified()) == 2
    w.run(at=w.now + 700)                                         # and only now is it "told"
    assert len(w.notified()) == 2


def test_a_missing_notify_is_an_error_not_a_silent_success(w):
    _no_login_problem(w)
    w.mp.setenv("CLAUDE_CREW_NOTIFY", str(w.d / "does-not-exist"))
    w.run()
    assert "notify could not run" in w.log() and "alerts" in w.state()
    assert all(w.state()["alerts"][k] < w.now - crew.ALERT_EVERY_S + crew.ALERT_RETRY_S + 1 for k in w.state()["alerts"])
    w.mp.setenv("CLAUDE_CREW_NOTIFY", str(w.d / "notify"))
    w.run(at=w.now + 600)
    assert len(w.notified()) == 1


# ── main(): a failure must not look like success ───────────────────────────────────────────────────────────────────
def test_main_exits_1_and_pushes_when_the_run_crashes(w):
    def boom(dry=False):
        raise RuntimeError("kaboom")
    w.mp.setattr(crew, "run_once", boom)
    assert crew.main([]) == 1
    assert "run failed (RuntimeError" in w.log()
    assert len([n for n in w.notified() if "job falhou" in n]) == 1
    assert crew.main([]) == 1 and len(w.notified()) == 1          # the same crash again: deduplicated


def test_main_exits_1_when_the_lock_cannot_be_opened(w, tmp_path):
    blocker = tmp_path / "a-file"
    blocker.write_text("")
    w.mp.setenv("GC_CITY_PATH", "")
    w.mp.setenv("CLAUDE_CREW_STATE", str(blocker / "state.json"))
    assert crew.main([]) == 1


def test_a_dry_run_that_loses_the_lock_says_so_instead_of_printing_nothing(w, capsys):
    lock = w.d / "city" / ".gc" / "claude-crew-account.lock"
    fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        rc = crew.main(["--dry-run"])
    finally:
        os.close(fd)
        crew.DRY = False
    assert rc == 0
    assert "lock" in capsys.readouterr().err


# ── Remote Control verification that cannot be fooled by silence ───────────────────────────────────────────────────
def _lstart(pid):
    return " ".join(subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                                   env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}).stdout.split())


def test_an_unreadable_sessions_dir_before_the_switch_is_not_reported_as_all_bridges_up(w):
    os.rename(w.d / "sessions", w.d / "sessions.gone")
    _switch_crypto_to_amb(w)
    assert w.state()["pending_verify"]["blind"] is True
    os.rename(w.d / "sessions.gone", w.d / "sessions")            # readable again at the check: this runs the BLIND branch, not the retry one
    w.run(at=w.now + 90)
    assert w.state()["rc_unjudged"]["blind"] is True and "pending_verify" not in w.state()
    assert "no list of bridges to compare" in w.log() and "all 0" not in w.log() and not w.notified()


def test_an_unreadable_sessions_dir_at_check_time_is_neither_success_nor_a_false_alarm_and_is_retried(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    os.rename(w.d / "sessions", w.d / "sessions.gone")
    w.run(at=w.now + 90)
    assert "still up" not in w.log() and "lost Remote Control" not in "".join(w.notified())
    assert "could not read the sessions dir" in w.log() and "pending_verify" in w.state()
    os.rename(w.d / "sessions.gone", w.d / "sessions")
    w.run(at=w.now + 150)
    assert "all 1 Remote Control bridges are still up" in w.log() and "pending_verify" not in w.state()


def test_a_session_file_that_cannot_be_read_is_said_not_counted_as_a_session_without_a_bridge(w):
    _session(w, os.getpid(), "cse_a")
    (w.d / "sessions" / "4242.json").write_text("{torn write")           # exists, but is not JSON: "don't know", not "no bridge"
    (w.d / "sessions" / "4343.json").write_text("[1, 2]")                # valid JSON that is not a session object
    (w.d / "sessions" / "4444.json").write_text(json.dumps({"pid": 4444}))   # readable, says it has no bridge: fine, silent
    assert set(crew.bridges()) == {os.getpid()}
    log = w.log()
    assert "2 session file(s) could not be read (4242.json, 4343.json)" in log and "4444.json" not in log
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert "session file(s) could not be read" in w.log()                # the switch run says it too, before it counts "1 bridge"


def test_no_bridge_at_all_says_there_was_nothing_to_verify(w):
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert "all 0" not in w.log() and "no Remote Control bridge existed" in w.log()


def test_a_reused_pid_is_not_a_live_bridge(w):
    me = os.getpid()
    d = {"pid": me, "bridgeSessionId": "cse_a", "procStart": "Mon Jan  1 00:00:00 2001"}   # some other process owns this pid now
    (w.d / "sessions" / f"{me}.json").write_text(json.dumps(d))
    assert crew.bridges() == {}
    d["procStart"] = _lstart(me)                                  # the genuine start time of the live process
    (w.d / "sessions" / f"{me}.json").write_text(json.dumps(d))
    assert list(crew.bridges()) == [me]


def test_sessions_that_ended_on_their_own_are_not_counted_as_bridges_that_are_up(w):
    me = os.getpid()
    gone = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        _session(w, me, "cse_a")
        _session(w, gone.pid, "cse_b")
        _switch_crypto_to_amb(w)
        assert set(w.state()["pending_verify"]["pids"]) == {str(me), str(gone.pid)}
    finally:
        gone.kill()
        gone.wait()                                               # this session ended by itself before the check
    w.run(at=w.now + 90)
    assert "all 2" not in w.log() and "1 of 2 Remote Control bridges are still up" in w.log()
    assert "ended on their own" in w.log() and not w.notified() and "pending_verify" not in w.state()


def test_when_every_session_ended_nothing_is_reported_as_up(w):
    gone = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        _session(w, gone.pid, "cse_b")
        _switch_crypto_to_amb(w)
    finally:
        gone.kill()
        gone.wait()
    w.run(at=w.now + 90)
    assert "still up" not in w.log() and "no session was left to verify" in w.log() and "pending_verify" not in w.state()


def test_a_verification_that_comes_too_late_is_not_blamed_on_the_switch(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    _session(w, me, None)
    w.run(at=w.now + crew.VERIFY_GIVE_UP_S + 600)                 # the machine slept, or the job stalled
    assert "rc_lost" not in w.state() and "pending_verify" not in w.state()
    assert not any("lost Remote Control" in n for n in w.notified()) and "too late" in w.log()


def test_the_bridge_check_also_runs_when_the_owner_cannot_be_told(w):
    me = os.getpid()
    _session(w, me, None)                                         # the bridge is gone
    w.default("crypto", blob("crypto"))
    w.tokens.clear()                                              # and the profile cannot say whose the default login is
    (w.d / "crew_state.json").write_text(json.dumps({"pending_verify": {"since": w.now - 100, "to": EMAIL["amb"],
                                                                         "pids": {str(me): "cse_a"}}}))
    w.decide("crypto")
    w.run()
    assert any("lost Remote Control" in n for n in w.notified())


# ══ gate fix (ga-llvuo4, verdict on 654892dc): "could not read" and "lost" are different verdicts ═══════════════════
def _lost_pushes(w):
    return [n for n in w.notified() if "lost Remote Control" in n]


def test_a_live_session_whose_file_cannot_be_read_at_check_time_is_unverified_not_lost(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    (w.d / "sessions" / f"{me}.json").write_text("{torn write")   # still running, but its file cannot be read right now
    w.run(at=w.now + 90)
    assert _lost_pushes(w) == [] and "rc_lost" not in w.state() and "pending_verify" not in w.state()
    assert w.state()["rc_unjudged"]["unverified"] == [me]         # its own counter, with the pid named
    log = w.log()
    assert f"[{me}]" in log and "Remote Control NOT verified" in log and "still up" not in log


def test_an_unreadable_file_that_cannot_be_tied_to_a_pid_leaves_every_missing_session_unverified(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    (w.d / "sessions" / f"{me}.json").unlink()                    # its own file is gone ...
    (w.d / "sessions" / "not-a-pid.json").write_text("{torn")     # ... and a file we cannot read might be where its bridge went
    w.run(at=w.now + 90)
    assert _lost_pushes(w) == [] and w.state()["rc_unjudged"]["unverified"] == [me]


def test_unreadable_and_lost_are_told_apart_in_the_same_check(w):
    me, parent = os.getpid(), os.getppid()
    _session(w, me, "cse_a")
    _session(w, parent, "cse_b")
    _switch_crypto_to_amb(w)
    (w.d / "sessions" / f"{me}.json").write_text("{torn write")   # cannot tell
    _session(w, parent, None)                                     # certainly lost
    w.run(at=w.now + 90)
    assert w.state()["rc_lost"]["pids"] == [parent] and w.state()["rc_unjudged"]["unverified"] == [me]
    assert len(_lost_pushes(w)) == 1 and f"the sessions [{parent}] lost Remote Control" in _lost_pushes(w)[0]   # exactly the lost one


# ══ gate fix (ga-llvuo4): a second switch must not silently drop the check the first one promised ═════════════════
def _flip_back_to_crypto(w, at):
    w.decide("crypto")
    return w.run(at=at)


def test_a_second_switch_before_the_first_check_is_judged_carries_the_first_check(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    _session(w, me, None)                                         # the first switch cost this session its bridge
    _flip_back_to_crypto(w, w.now + 30)                           # the pool flips back before the 60 s check
    assert w.log().count("SWITCH crews") == 2                     # a second switch really happened
    assert str(me) in w.state()["pending_verify"]["pids"]         # the first check's session is still on the list
    assert "still pending" in w.log() and "carried" in w.log()
    w.run(at=w.now + 130)
    assert w.state()["rc_lost"]["pids"] == [me] and len(_lost_pushes(w)) == 1
    assert "no Remote Control bridge existed" not in w.log()      # not the plausible-but-false empty


def test_a_second_switch_after_a_blind_first_one_stays_blind(w):
    os.rename(w.d / "sessions", w.d / "sessions.gone")
    _switch_crypto_to_amb(w)                                      # blind: the first switch could not list the bridges
    os.rename(w.d / "sessions.gone", w.d / "sessions")
    _session(w, os.getpid(), "cse_a")
    _flip_back_to_crypto(w, w.now + 30)                           # the second one can, but not what the first one cost
    assert w.state()["pending_verify"]["blind"] is True
    w.run(at=w.now + 130)
    assert w.state()["rc_unjudged"]["blind"] is True and "still up" not in w.log() and _lost_pushes(w) == []


def test_a_pending_check_that_is_not_a_dict_does_not_break_the_next_switch(w):
    _session(w, os.getpid(), "cse_a")
    (w.d / "crew_state.json").write_text(json.dumps({"pending_verify": "garbage"}))
    _switch_crypto_to_amb(w)
    assert str(os.getpid()) in w.state()["pending_verify"]["pids"]


# ══ gate fix (ga-llvuo4): the rc-lost push promises a retry; it must be reachable ═════════════════════════════════
def test_an_undelivered_rc_lost_push_is_retried_and_then_told_once(w):
    me = os.getpid()
    _session(w, me, "cse_a")
    _switch_crypto_to_amb(w)
    _session(w, me, None)
    w.mp.setenv("FAKE_NOTIFY_FAIL", "1")                          # the notify binary is down
    w.run(at=w.now + 90)
    assert len(_lost_pushes(w)) == 1 and w.state()["rc_lost"]["push_pending"] is True
    w.run(at=w.now + 120)                                         # inside ALERT_RETRY_S: not hammered
    assert len(_lost_pushes(w)) == 1
    w.mp.delenv("FAKE_NOTIFY_FAIL")
    w.run(at=w.now + 90 + crew.ALERT_RETRY_S + 10)                # after it: tried again, and now it gets through
    assert len(_lost_pushes(w)) == 2 and w.state()["rc_lost"]["push_pending"] is False
    w.run(at=w.now + 90 + 3 * crew.ALERT_RETRY_S)                 # told is told: no nagging until the next switch
    assert len(_lost_pushes(w)) == 2


# ══ gate fix (ga-llvuo4): `ps` that complains is "could not ask", not "no such process" ════════════════════════════
def test_a_ps_that_complains_is_could_not_ask_not_no_such_process(w):
    real = subprocess.run

    def fake(argv, **kw):
        if "lstart=" in argv:
            return subprocess.CompletedProcess(argv, 1, "", "ps: something is wrong\n")
        return real(argv, **kw)
    w.mp.setattr(crew.subprocess, "run", fake)
    assert crew.proc_start(os.getpid()) is None                   # not '' (= it does not exist)
    assert crew.alive(os.getpid(), "Mon Jan  1 00:00:00 2001") is True    # so the kill(0) fallback answers, and the pid is alive
    w.mp.setattr(crew.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 1, "", ""))
    assert crew.proc_start(os.getpid()) == ""                     # a plain rc=1 with nothing on stderr IS "no such process"


def test_a_pid_that_is_not_a_process_is_never_alive(w):
    for pid in (0, -1):                                           # kill(0, 0) / kill(-1, 0) signal a whole group and "succeed"
        assert crew.alive(pid) is False and crew.alive(pid, "Mon Jan  1 00:00:00 2001") is False
    (w.d / "sessions" / "0.json").write_text(json.dumps({"pid": 0, "bridgeSessionId": "cse_zero"}))
    assert crew.bridges() == {}                                   # a bogus session file is not a live bridge


# ── only the OAuth part of a blob moves ────────────────────────────────────────────────────────────────────────────
def test_only_the_oauth_part_moves_never_the_rest_of_the_blob(w):
    cur = blob("crypto", rt="crypto-rotated")
    cur["mcpOAuth"] = {"srv|default": {"accessToken": "mcp-default"}}
    own = blob("crypto", rt="crypto-old")
    own["mcpOAuth"] = {"srv|own": {"accessToken": "mcp-own"}}
    amb = blob("amb")
    amb["mcpOAuth"] = {"srv|amb": {"accessToken": "mcp-amb"}}
    w.default("crypto", cur)
    w.account("crypto", own)
    w.account("amb", amb)
    w.decide("amb")
    w.run()
    d = w.get(crew.DEFAULT_SERVICE)
    assert _rt(d) == "sk-ant-ort01-amb-ref" and d["mcpOAuth"] == cur["mcpOAuth"]       # amb's MCP logins did not ride along
    o = w.get(_own(w, "crypto"))
    assert _rt(o) == "sk-ant-ort01-crypto-rotated-ref" and o["mcpOAuth"] == own["mcpOAuth"]


def test_a_new_reserve_item_holds_only_the_login(w):
    t = blob("terr")
    t["mcpOAuth"] = {"srv": {"accessToken": "mcp-terr"}}
    w.default("terr", t)
    w.account("crypto", blob("crypto"))
    w.decide("crypto")
    w.run()
    assert list(w.get(crew.reserve_service(EMAIL["terr"]))) == ["claudeAiOauth"]


def test_a_command_longer_than_the_security_stdin_line_is_refused_not_truncated(w):
    """Measured 07/10: `security -i` cuts a stdin line at 4096 bytes and runs the rest as a SECOND command."""
    big = blob("x")
    big["mcpOAuth"] = {"srv": {"blob": "p" * 3000}}
    assert crew.kc_write(crew.DEFAULT_SERVICE, "athos", big) is False
    assert w.writes() == [] and "cut by `security -i`" in w.log()
    cur = blob("crypto")
    cur["mcpOAuth"] = {"srv": {"blob": "p" * 3000}}
    w.default("crypto", cur)
    w.account("amb", blob("amb"))
    w.decide("amb")
    w.run()
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-crypto-ref"
    assert any("could not write" in n for n in w.notified())


# ── heal: the default holds no full login ──────────────────────────────────────────────────────────────────────────
def test_heal_falls_back_to_another_account_when_the_wanted_one_has_no_login(w):
    w.put(crew.DEFAULT_SERVICE, blob("old", refresh=False))
    w.account("amb", blob("amb", refresh=False))                  # the pool's pick: a setup-token only
    w.account("b85", blob("b85"))
    w.decide("amb")
    w.run()
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-b85-ref"
    assert any("Remote Control is broken" in n for n in w.notified())
    assert any(EMAIL["amb"] in n and "no refresh token" in n for n in w.notified())     # the missing login is NAMED, with why


def test_heal_that_finds_no_login_anywhere_names_what_is_missing(w):
    w.put(crew.DEFAULT_SERVICE, blob("old", refresh=False))
    w.decide("amb")
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert any("cannot heal" in n and EMAIL["amb"] in n for n in w.notified())


def test_heal_with_a_blank_pool_pick_still_heals_from_any_account(w):
    w.put(crew.DEFAULT_SERVICE, blob("old", refresh=False))
    w.account("b85", blob("b85"))
    (w.d / "pool_decision.json").write_text(json.dumps({"current": "", "updated": crew._iso(w.now), "schema": 1}))
    w.run()
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-b85-ref"


def test_heal_alert_with_a_blank_pool_pick_still_reads_as_a_sentence(w):
    w.put(crew.DEFAULT_SERVICE, blob("old", refresh=False))
    (w.d / "pool_decision.json").write_text(json.dumps({"current": "", "updated": crew._iso(w.now), "schema": 1}))
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()
    assert any("cannot heal" in n and "log  in" not in n for n in w.notified())


def test_a_default_without_a_full_login_is_alerted_even_when_its_owner_is_known(w):
    w.default("crypto", blob("crypto", refresh=False))            # the profile answers (crypto), but it is a setup-token
    w.account("crypto", blob("crypto"))
    w.decide("crypto")                                            # the pool is already "on" crypto: nothing to follow...
    w.run()
    assert any("Remote Control is broken" in n for n in w.notified())     # ...yet Remote Control IS broken
    assert _rt(w.get(crew.DEFAULT_SERVICE)) == "sk-ant-ort01-crypto-ref"


def test_a_source_that_could_not_be_read_stops_the_search_instead_of_falling_to_a_stale_reserve(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))
    w.put(crew.reserve_service(EMAIL["amb"]), blob("amb", rt="stale"))
    w.decide("amb")
    w.mp.setenv("FAKE_SEC_FAIL", _own(w, "amb"))
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes()


# ── gate round 4 (ga-03ody6): a wanted login that COULD NOT BE READ is not "the wanted account has none" ──────────────
# Fails if choose() goes back to dropping load_source's "unreadable" answer when the current account is exhausted: the
# crews would be moved to the fallback on a failed read, with a push saying the wanted account "has no full login".
def _unreadable_wanted(w, exhausted):
    w.default("crypto", blob("crypto"))
    w.account("crypto", blob("crypto"))
    w.account("amb", blob("amb"))                                  # a full login IS stored for amb...
    w.account("b85", blob("b85"))                                  # ...and one to fall to if amb really had none
    w.decide("amb", exhausted=exhausted)
    w.mp.setenv("FAKE_SEC_FAIL", _own(w, "amb"))                   # ...but amb's item cannot be read (exit 1 = unknown, not 44)


def test_an_exhausted_account_is_not_left_for_a_fallback_on_a_wanted_login_that_could_not_be_read(w):
    _unreadable_wanted(w, exhausted=["crypto"])
    w.run()
    assert crew.DEFAULT_SERVICE not in w.writes() and "SWITCH" not in w.log()      # the crews did not move
    assert w.state()["current"] == EMAIL["crypto"]
    said = " ".join(w.notified())
    assert "could not be read" in said                                             # the push names what happened...
    assert "has no full login" not in said and "fall to" not in said              # ...and does not claim the opposite
    w.mp.delenv("FAKE_SEC_FAIL")                                                   # the read clears: the pool's pick is followed
    w.run()
    assert w.state()["current"] == EMAIL["amb"] and w.state()["last_switch"]["reason"] == "follow the pool decision"


def test_an_unreadable_wanted_login_is_not_reported_as_a_login_to_redo_by_hand(w):
    _unreadable_wanted(w, exhausted=[])                            # crypto still has balance: the old branch
    w.run()
    said = " ".join(w.notified())
    assert crew.DEFAULT_SERVICE not in w.writes() and "could not be read" in said
    assert "human step" not in said and "log " + EMAIL["amb"] + " in" not in said   # nobody is told to redo a login that exists


def test_the_stuck_push_does_not_claim_there_is_no_login_when_a_candidate_could_not_be_read(w):
    w.default("crypto", blob("crypto"))
    w.account("amb", blob("amb"))                                  # nobody else has a usable login that could be READ
    w.decide("terr", exhausted=["crypto"])
    w.mp.setenv("FAKE_SEC_FAIL", _own(w, "amb"))
    w.run()
    stuck = [n for n in w.notified() if "STUCK" in n]
    assert crew.DEFAULT_SERVICE not in w.writes() and stuck
    assert EMAIL["amb"] in stuck[0] and "could not be read" in stuck[0]            # the unknown is named, not folded into "none"


# ── state ─────────────────────────────────────────────────────────────────────────────────────────────────────────
def test_a_corrupt_state_file_is_logged_not_silently_reset(w):
    (w.d / "crew_state.json").write_text("{not json")
    w.default("crypto", blob("crypto"))
    w.decide("crypto")
    w.run()
    assert "state file" in w.log() and "corrupt" in w.log() and "state_reset" in w.state()


def test_a_missing_state_file_is_normal_and_silent(w):
    w.default("crypto", blob("crypto"))
    w.decide("crypto")
    w.run()
    assert "state file" not in w.log()


# ── the script as launchd runs it: empty environment, both interpreters ───────────────────────────────────────────
SEAMS = ("FAKE_SEC_DIR", "CLAUDE_CREW_SECURITY", "CLAUDE_CREW_NOTIFY", "CLAUDE_CREW_STATE", "CLAUDE_CREW_DECISION",
         "CLAUDE_CREW_SESSIONS_DIR", "CLAUDE_CREW_ACCOUNTS_DIR", "CLAUDE_CREW_USER", "GC_CITY_PATH", "CLAUDE_CREW_PROFILE_URL",
         "CLAUDE_CREW_NOW")


def _env_i(w, interpreter, *args):
    env = [f"{k}={os.environ[k]}" for k in SEAMS] + [f"PATH={_GUARD['dir']}/bin:/usr/bin:/bin", f"HOME={w.d / 'home'}"]
    return subprocess.run(["/usr/bin/env", "-i", *env, interpreter, str(SCRIPT), *args], capture_output=True, text=True, timeout=60)


INTERPRETERS = [sys.executable] + (["/usr/bin/python3"] if os.path.exists("/usr/bin/python3") and sys.executable != "/usr/bin/python3" else [])


@pytest.mark.parametrize("interpreter", INTERPRETERS)       # the plist runs /usr/bin/python3 (3.9): the suite must too
def test_the_real_script_run_from_an_empty_environment_stays_inside_the_test_world(w, interpreter):
    w.default("crypto", blob("crypto"))
    w.account("b85", blob("b85"))
    w.decide("b85")
    r = _env_i(w, interpreter)
    assert r.returncode == 0, r.stderr
    assert "SWITCH crews" in w.log() and w.state()["current"] == EMAIL["b85"]       # log + state landed in the tmp world
    w.account("amb", blob("amb", refresh=False))
    w.decide("amb")
    r = _env_i(w, interpreter)                                    # an alert: the push must go to the PINNED notify
    assert r.returncode == 0, r.stderr
    assert len(w.notified()) == 1 and "job falhou" in w.notified()[0]
    assert not _GUARD["hits"].exists()
    d = _env_i(w, interpreter, "--dry-run")
    assert d.returncode == 0 and "crew" in d.stderr and len(w.notified()) == 1


# ══ ga-ci3uao: a bridge that is up is not a session on the new account ═══════════════════════════════════════════
# 14/10: the switch ran, VERIFY said "all 5 Remote Control bridges are still up" - and the Mayor and three crews sat on the old
# account's limit screen for 12 minutes until the Athos switched them by hand. The check now LOOKS at each session's screen.
PROMPT_BOX = "● Done.\n\n╭────────────────────────────╮\n│ >                          │\n╰────────────────────────────╯\n  ? for shortcuts\n"
LIMIT_MODAL = ("● Working on it...\n\n You've hit your weekly limit · resets 8pm\n\n What do you want to do?\n\n"
               " ❯ 1. Stop and wait for limit to reset\n   2. Wait here, then continue automatically at Oct 14 at 8pm\n"
               "   3. Upgrade your plan\n\n Enter to confirm · Esc to cancel\n")
BANNER_ONLY = " You've hit your weekly limit · resets 8pm\n\n" + PROMPT_BOX
QUOTED_MODAL = ("● The bead shows the screen:\n  > What do you want to do?\n  > 1. Stop and wait for limit to reset\n"
                "  > Enter to confirm · Esc to cancel\n\n" + PROMPT_BOX)
PERMISSION_DIALOG = "Bash command\n  rm -rf x\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n"
OTHER_QUESTION = "What do you want to do?\n ❯ 1. Resume the conversation\n   2. Start a new one\n\n Enter to confirm · Esc to cancel\n"
REVERSED_ORDER = " ❯ 1. Stop and wait for limit to reset\n What do you want to do?\n\n Enter to confirm · Esc to cancel\n"
OUTPUT_AFTER_MODAL = LIMIT_MODAL + "\n● more output came after it\n"


def _rc(w, pid, pane, text, *, name="Mayor", tmux=True, **kw):
    """A Remote Control session that lives in a tmux pane showing `text` (the pane's process is the session's own, as in production)."""
    d = {"pid": pid, "bridgeSessionId": f"cse_{pid}", "name": name, "status": "busy", "procStart": _lstart(pid)}
    if tmux:
        d["tmux"] = f"gastown__x:@3.{pane}"
    (w.d / "sessions" / f"{pid}.json").write_text(json.dumps(d))
    if tmux:
        w.pane(pane, pid, text, **kw)


@pytest.mark.parametrize("text,want", [
    (LIMIT_MODAL, "limit"), (PROMPT_BOX, "clear"), ("", "clear"), (BANNER_ONLY, "banner"),
    (QUOTED_MODAL, "clear"),               # an agent quoting the modal has its prompt box under the quote
    (PERMISSION_DIALOG, "clear"),          # same footer, another question
    (OTHER_QUESTION, "clear"),             # same question, no "Stop and wait for limit to reset"
    (REVERSED_ORDER, "clear"),             # option before the question
    (OUTPUT_AFTER_MODAL, "banner"),        # the modal is not the last thing on the screen: it is not open any more
])
def test_the_limit_modal_is_recognised_only_when_it_is_the_last_thing_on_the_screen(text, want):
    assert crew.screen_verdict(text) == want


def test_a_session_on_the_limit_screen_fails_the_verify_and_the_push_names_it(w):
    me = os.getpid()
    _rc(w, me, "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert "VERIFY FAILED" in w.log() and "Mayor" in w.log() and "VERIFY ok" not in w.log()
    v = w.state()["verify_last"]
    assert v["verdict"] == "failed" and v["limit"] == [me] and v["clear"] == 0 and v["to"] == EMAIL["amb"]
    assert w.state()["limit_watch"]["pids"][str(me)]["name"] == f"Mayor ({me})"
    pushes = [n for n in w.notified() if "limit screen" in n]
    assert len(pushes) == 1 and "Mayor" in pushes[0] and "job falhou" in pushes[0] and "did NOT pick up the new login" in pushes[0]
    assert "automatic Escape is off" in pushes[0] and w.keys() == []        # a human has to arm the key


def test_when_every_session_was_looked_at_and_none_is_on_the_limit_screen_the_verify_is_ok(w):
    me = os.getpid()
    _rc(w, me, "%5", PROMPT_BOX)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert "VERIFY ok - none of the 1 sessions looked at is on claude's limit screen" in w.log()
    v = w.state()["verify_last"]
    assert v["verdict"] == "ok" and v["looked"] == 1 and v["clear"] == 1 and v["limit"] == []
    assert "limit_watch" not in w.state() and not w.notified() and w.keys() == []


@pytest.mark.parametrize("how", ["no-tmux-field", "tmux-down", "no-tmux-binary", "pane-of-another-process", "pane-unknown"])
def test_a_screen_that_cannot_be_looked_at_is_not_verified_and_never_ok(w, monkeypatch, how):
    me = os.getpid()
    other = subprocess.Popen(["sleep", "60"])
    try:
        _rc(w, me, "%5", LIMIT_MODAL, tmux=(how != "no-tmux-field"))
        if how == "tmux-down":
            monkeypatch.setenv("FAKE_TMUX_DOWN", "1")
        elif how == "no-tmux-binary":
            monkeypatch.setenv("CLAUDE_CREW_TMUX", str(w.d / "nowhere"))
        elif how == "pane-of-another-process":
            w.pane("%5", other.pid, LIMIT_MODAL)                   # the pane id was recycled: that screen is somebody else's
        elif how == "pane-unknown":
            w.pane("%5", me, LIMIT_MODAL)
            (w.d / "sessions" / f"{me}.json").write_text(json.dumps({**json.loads((w.d / "sessions" / f"{me}.json").read_text()),
                                                                     "tmux": "gastown__x:@3.%9"}))
        _switch_crypto_to_amb(w)
        w.run(at=w.now + 90)
    finally:
        other.kill()
        other.wait()
    assert "VERIFY NOT VERIFIED" in w.log() and "VERIFY ok" not in w.log() and "VERIFY FAILED" not in w.log()
    assert w.state()["verify_last"]["verdict"] == "not-verified" and w.state()["verify_last"]["cannot_tell"] == [me]
    assert "limit_watch" not in w.state() and not w.notified() and w.keys() == []     # cannot tell: no push, no key


def test_the_limit_message_without_the_modal_is_cannot_tell_never_stuck_and_never_pressed(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", BANNER_ONLY)
    _switch_crypto_to_amb(w)
    for k in (90, 150, 210):
        w.run(at=w.now + k)
    assert w.state()["verify_last"]["verdict"] == "not-verified" and "limit_watch" not in w.state()
    assert "the limit message is on screen but not the modal" in w.log()
    assert w.keys() == [] and not w.notified()


def test_a_session_that_started_after_the_switch_is_not_judged_by_it(w):
    _rc(w, os.getpid(), "%5", PROMPT_BOX)
    _switch_crypto_to_amb(w)
    newcomer = subprocess.Popen(["sleep", "60"])
    try:
        _rc(w, newcomer.pid, "%6", LIMIT_MODAL, name="Newcomer")   # born after the rewrite: its limit is its own
        w.run(at=w.now + 90)
    finally:
        newcomer.kill()
        newcomer.wait()
    assert w.state()["verify_last"]["looked"] == 1 and "limit_watch" not in w.state() and "Newcomer" not in w.log()
    assert not any("%6" in json.dumps(c) for c in w.tmux_calls())


def test_a_bridge_that_is_lost_keeps_the_verify_from_being_ok_even_when_the_rest_is_clear(w):
    a, b = os.getpid(), subprocess.Popen(["sleep", "60"])
    try:
        _rc(w, a, "%5", PROMPT_BOX)
        _rc(w, b.pid, "%6", PROMPT_BOX, name="Thies")
        _switch_crypto_to_amb(w)
        (w.d / "sessions" / f"{b.pid}.json").write_text(json.dumps({"pid": b.pid, "name": "Thies", "procStart": _lstart(b.pid)}))   # bridge gone
        w.run(at=w.now + 90)
    finally:
        b.kill()
        b.wait()
    assert any("lost Remote Control" in n for n in w.notified())
    assert "VERIFY ok" not in w.log() and w.state()["verify_last"]["verdict"] == "not-verified"


def test_unarmed_a_stuck_session_is_watched_and_alerted_but_never_pressed(w):
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    for k in (90, 150, 210, 270):
        w.run(at=w.now + k)
    assert w.keys() == [] and not any(c[:1] == ["send-keys"] for c in w.tmux_calls())
    assert str(os.getpid()) in w.state()["limit_watch"]["pids"] and len(w.notified()) == 1


def test_armed_one_escape_after_the_settle_and_a_second_look_then_the_watch_ends(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL, escape_clears=True, clear_text=PROMPT_BOX)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert w.keys() == [] and "will be tried" in w.notified()[0]        # found on this run: seen once is not enough to press
    w.run(at=w.now + 150)
    assert w.keys() == ["%5 Escape"] and "Escape sent (try 1 of 2)" in w.log()
    w.run(at=w.now + 210)
    assert w.keys() == ["%5 Escape"] and "left the limit screen" in w.log() and "limit_watch" not in w.state()
    assert not secrets_in(w.log() + (w.d / "crew_state.json").read_text() + "".join(w.notified()), w)


def test_an_escape_that_does_not_take_is_repeated_once_after_a_minute_then_the_failure_is_pushed(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.run(at=w.now + 150)
    assert len(w.keys()) == 1
    w.run(at=w.now + 180)                                                # only 30 s after the first key
    assert len(w.keys()) == 1
    w.run(at=w.now + 215)
    assert len(w.keys()) == 2
    w.run(at=w.now + 280)
    assert len(w.keys()) == 2                                            # MAX_ESC_TRIES: never a third
    assert any("after 2 Escape(s) from this script" in n for n in w.notified())


def test_armed_but_the_new_account_is_itself_exhausted_no_key(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.decide("amb", exhausted=["amb"])
    w.run(at=w.now + 150)
    assert w.keys() == [] and "no Escape sent" in w.log() and "itself registered exhausted" in w.log()


def test_armed_but_the_default_item_does_not_hold_the_new_login_no_key(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.default("crypto", blob("crypto", rt="crypto-again"))               # somebody put another login there; the profile says whose
    w.run(at=w.now + 150)
    assert w.keys() == [] and "no Escape sent - cannot tell that the default item holds" in w.log()


def test_armed_but_too_soon_after_the_switch_no_key(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    st = w.state()
    st["last_switch"]["at"] = w.now + 100                                # a (re)switch 10 s before the next run: claude has not re-read yet
    (w.d / "crew_state.json").write_text(json.dumps(st))
    w.run(at=w.now + 110)
    assert w.keys() == [] and "has not been in place long enough" in w.log()


def test_armed_but_the_pane_changed_between_the_look_and_the_key_nothing_is_sent(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.pane_set("%5", captures=0, flip_after=1, flip_text=PROMPT_BOX)     # the first read (the watch) sees the modal, the second (the key) does not
    w.run(at=w.now + 150)
    assert w.keys() == [] and "not on the limit screen when the key was due" in w.log()


def test_the_escape_knob_the_env_beats_the_file_and_off_is_the_default(w, monkeypatch):
    assert crew.unstick_armed() is False
    (w.d / "city" / ".gc" / "crew-unstick-on").write_text("")
    assert crew.unstick_armed() is True
    monkeypatch.setenv("GC_CREW_UNSTICK", "0")
    assert crew.unstick_armed() is False                                 # the kill switch wins over the file
    (w.d / "city" / ".gc" / "crew-unstick-on").unlink()
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    assert crew.unstick_armed() is True


def test_a_dry_run_looks_but_never_presses_pushes_or_writes(w, monkeypatch, capsys):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    pushes, state = len(w.notified()), (w.d / "crew_state.json").read_text()
    capsys.readouterr()
    w.run(dry=True, at=w.now + 150)
    assert w.keys() == [] and len(w.notified()) == pushes and (w.d / "crew_state.json").read_text() == state
    assert f"DRY-RUN would send Mayor ({os.getpid()}) one Escape" in capsys.readouterr().err


def test_a_watch_that_has_run_its_course_is_dropped_without_a_key(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.run(at=w.now + 90 + crew.LIMIT_WATCH_S + 1)
    assert w.keys() == [] and "the watch is dropped" in w.log() and "limit_watch" not in w.state()


def test_a_watched_session_that_ends_on_its_own_is_dropped(w):
    other = subprocess.Popen(["sleep", "60"])
    try:
        _rc(w, other.pid, "%6", LIMIT_MODAL, name="Crew")
        _switch_crypto_to_amb(w)
        w.run(at=w.now + 90)
        assert str(other.pid) in w.state()["limit_watch"]["pids"]
    finally:
        other.kill()
        other.wait()
    w.run(at=w.now + 150)
    assert "ended on its own while on the limit screen" in w.log() and "limit_watch" not in w.state()


def test_a_limit_watch_record_that_cannot_be_read_is_dropped_and_the_switch_still_happens(w):
    (w.d / "crew_state.json").write_text(json.dumps({"limit_watch": "garbage"}))
    _switch_crypto_to_amb(w)
    assert "limit_watch record in the state cannot be read" in w.log()
    assert w.state()["last_switch"]["to"] == EMAIL["amb"] and "limit_watch" not in w.state()


def test_a_bug_in_the_screen_check_does_not_cost_the_bridge_verdict_or_the_switch(w, monkeypatch):
    _rc(w, os.getpid(), "%5", PROMPT_BOX)
    _switch_crypto_to_amb(w)
    monkeypatch.setattr(crew, "look", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    w.run(at=w.now + 90)
    assert "the screen check failed (RuntimeError)" in w.log() and "all 1 Remote Control bridges are still up" in w.log()
    assert w.state()["verify_last"]["verdict"] == "not-verified" and "pending_verify" not in w.state()


def test_a_bug_in_the_watch_does_not_stop_the_switch(w, monkeypatch):
    monkeypatch.setattr(crew, "watch_limits", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    (w.d / "crew_state.json").write_text(json.dumps({"limit_watch": {"to": EMAIL["amb"], "pids": {}}}))
    _switch_crypto_to_amb(w)
    assert "the limit-screen watch failed (RuntimeError)" in w.log() and w.state()["last_switch"]["to"] == EMAIL["amb"]


def test_a_pane_is_the_sessions_when_its_process_is_an_ancestor_not_only_when_it_is_the_same_pid(w):
    me = os.getpid()
    w.pane("%5", os.getppid(), LIMIT_MODAL)                              # claude started by a wrapper that the pane runs
    assert crew.look(me, "gastown__x:@3.%5") == ("limit", "%5", "")
    stranger = subprocess.Popen(["sleep", "60"])
    try:
        w.pane("%5", stranger.pid, LIMIT_MODAL)
        assert crew.look(me, "gastown__x:@3.%5")[0] == "unknown"
    finally:
        stranger.kill()
        stranger.wait()


def test_a_session_name_cannot_smuggle_control_characters_or_a_command_into_a_push():
    lbl = crew._label("Ma\nyor\x1b[31m; rm -rf /", 5)
    assert "\n" not in lbl and "\x1b" not in lbl and "[" not in lbl and lbl.endswith("(5)")
    assert crew._label(None, 7) == "pid 7" and crew._label("???", 8) == "pid 8"


def test_when_there_is_no_time_left_the_screens_are_cannot_tell_and_nothing_slow_stands_in_front_of_the_switch(w, monkeypatch):
    monkeypatch.setattr(crew, "LOOK_BUDGET_S", -1)                       # a loaded machine: every tmux/ps call would be slow
    _rc(w, os.getpid(), "%5", LIMIT_MODAL)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    assert "no time was left to look at every screen in this run" in w.log()
    assert w.state()["verify_last"]["verdict"] == "not-verified" and "limit_watch" not in w.state()
    assert w.tmux_calls() == [] and not w.notified()                     # not looked at is not "stuck" and not "clear"


# ══ ga-yqzedv: the limit MESSAGE without the modal is the real stall, and nothing watched it ══════════════════════
# 07/10 on: the automatic Escape never fired. The watch only started from the MODAL, but the real cases show the 429 arriving as a
# turn that ENDS with "You've hit your weekly limit · resets ..." as its last output - no modal, the session idle above its prompt box.
# That screen was "cannot tell" for ever (it may be an old line in the scrollback), so there was no push, no watch, no key.
#
# The fixtures use claude 2.1.310's REAL chrome (measured on live panes 25/10: a rule, the `❯` prompt, a rule, a changing statusline).
# The old PROMPT_BOX above (╭─╮ │ > │) is not what that version draws. HONEST CAVEAT: no pane in this state existed to capture, so the
# message line is the measured TEXT (from the transcript's rate_limit record) placed where claude puts a turn's last output; the glyph
# in front of it is not measured, which is why the match tolerates any non-word prefix.
RULE = "─" * 80
REAL_BOX = (f"{RULE}\n❯ \n{RULE}\n  👥 0 workers · 🚦 running 2/3 6c179cf040677bf559f74e\n  [Opus 5.5] ctx: 22.0% (220k/1000k)\n"
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent\n")
LIMIT_MSG = "  ⎿  You've hit your weekly limit · resets Oct 28 at 8pm (America/Sao_Paulo)\n"
STALLED = "⏺ Vou rodar o teste.\n\n⏺ Bash(pytest -q)\n  ⎿  12 passed\n\n" + LIMIT_MSG + "\n" + REAL_BOX
STALLED_FOOTER_MOVED = STALLED.replace("ctx: 22.0%", "ctx: 23.4%")                       # the statusline ticks on its own: not activity
STALLED_TYPING = STALLED.replace("❯ \n", "❯ continua\n")                                  # somebody typed in the prompt: activity
OLD_MESSAGE_THEN_WORK = ("⏺ Vou rodar o teste.\n\n" + LIMIT_MSG + "\n⏺ Voltei, rodando de novo.\n  ⎿  13 passed\n\n"
                         "✻ Baked for 2m 1s · done 1:01 PM\n\n" + REAL_BOX)
QUOTED_IN_PROSE = ("⏺ A mensagem que a crew viu foi You've hit your weekly limit · resets 8pm, e o modal não abriu.\n"
                   "  Vou olhar o pane.\n\n" + REAL_BOX)
NO_MESSAGE = "⏺ Done.\n\n✻ Baked for 11m 51s · done 1:01 PM\n\n" + REAL_BOX


@pytest.mark.parametrize("text,stopped", [
    (STALLED, True),
    (STALLED_FOOTER_MOVED, True),
    (STALLED_TYPING, True),
    (OLD_MESSAGE_THEN_WORK, False),     # something was written after it: it is not the last output, the session moved on
    (QUOTED_IN_PROSE, False),           # the words inside a sentence of the agent's own: not the message
    (NO_MESSAGE, False),
    (BANNER_ONLY, False),               # the OUTDATED box: a layout this script has not measured is "cannot tell", never "stopped"
    (LIMIT_MODAL, False),               # the modal has its own verdict
    (REAL_BOX, False),
    ("", False),
])
def test_the_limit_message_is_the_last_output_only_on_the_measured_layout(text, stopped):
    assert (crew.banner_last(text) is not None) is stopped


def test_the_screen_fingerprint_follows_what_the_session_does_and_not_the_statusline():
    f = crew.banner_last(STALLED)
    assert crew.banner_last(STALLED_FOOTER_MOVED) == f                                   # footer: not activity
    assert crew.banner_last(STALLED_TYPING) != f                                         # the prompt box: activity
    assert crew.banner_last(STALLED.replace("12 passed", "11 passed")) != f              # the transcript: activity


def _transcript(w, name, pid, kind):
    """The session's transcript where claude keeps it (<config>/projects/<cwd with every non-alphanumeric as ->/<sessionId>.jsonl).
    kind: 'limit' = the last conversation record is the rate_limit API error (what the 25/10 oracle transcript really ends with: the
    error, then a `system` record), dated 30 s AFTER the switch (the real one came 32 s after: 15:40:18Z switch, 15:40:50Z error);
    'before' = the same, dated an hour BEFORE it (a session idle on an old message); 'undated' = no timestamp on the error;
    'later' = work after it; 'garbage' = the tail cannot be parsed; None = no file at all."""
    proj = w.d / "projects" / re.sub(r"[^A-Za-z0-9]", "-", f"/work/{name}")
    proj.mkdir(parents=True, exist_ok=True)
    f = proj / f"sess-{pid}-0000.jsonl"
    if kind is None:
        f.unlink(missing_ok=True)
        return
    err = {"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit", "timestamp": crew._iso(w.now + (-3600 if kind == "before" else 30)),
           "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": "You've hit your weekly limit · resets Oct 28 at 8pm"}]}}
    recs = [{"type": "user", "message": {"role": "user", "content": "roda o teste"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash"}]}},
            {"type": "api-request-blob", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash"}]}},
            {"type": "api-request"}, err, {"type": "system"}]
    if kind == "undated":
        err.pop("timestamp")
    if kind == "later":
        recs += [{"type": "user", "message": {"role": "user", "content": "continua"}},
                 {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}, {"type": "system"}]
    f.write_text("\n".join(json.dumps(r) for r in recs) + ("\n{not json" if kind == "garbage" else "") + "\n")


def _stalled(w, pid, pane="%5", text=STALLED, *, name="Mayor", status="idle", transcript="limit", gc_name="gastown__mayor", **kw):
    """A Remote Control session whose screen shows the limit message as its last output, in the shape of a real session file."""
    _rc(w, pid, pane, text, name=name, **kw)
    f = w.d / "sessions" / f"{pid}.json"
    d = json.loads(f.read_text())
    d.update(status=status, sessionId=f"sess-{pid}-0000", cwd=f"/work/{name}", tmux=f"{gc_name}:@3.{pane}")
    f.write_text(json.dumps(d))
    _transcript(w, name, pid, transcript)


def _run_to(w, *offsets):
    for k in offsets:
        w.run(at=w.now + k)


def test_the_stall_window_is_ten_minutes():
    assert crew.STALL_S == 600


def test_the_message_as_last_output_goes_on_the_banner_watch_and_the_verify_stays_not_verified(w):
    me = os.getpid()
    _stalled(w, me)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    st = w.state()
    assert st["verify_last"]["verdict"] == "not-verified" and "limit_watch" not in st       # unproven: still "cannot tell" at the first look
    rec = st["banner_watch"]["pids"][str(me)]
    assert st["banner_watch"]["to"] == EMAIL["amb"] and rec["fp"] == crew.banner_last(STALLED) and rec["since"] == w.now + 90
    assert "last thing on the screen" in w.log() and w.keys() == [] and not w.notified()


def test_a_pane_that_keeps_changing_is_moving_and_is_never_called_stopped(w):
    me = os.getpid()
    _stalled(w, me)
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 300)
    w.pane_set("%5", text=STALLED_TYPING)                                                 # activity at +400: the clock starts over
    _run_to(w, 400, 690)                                                                  # 600 s after the FIRST look, only 290 s after the change
    assert not w.notified() and w.state()["banner_watch"]["pids"][str(me)]["since"] == w.now + 400
    assert "moving" in w.log()
    _run_to(w, 1000)                                                                      # 600 s unchanged now
    assert len(w.notified()) == 1 and "limit message" in w.notified()[0]


def test_a_statusline_that_ticks_does_not_keep_a_stopped_session_looking_alive(w):
    _stalled(w, os.getpid())
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 300)
    w.pane_set("%5", text=STALLED_FOOTER_MOVED)
    _run_to(w, 690)
    assert len(w.notified()) == 1


def test_stopped_for_ten_minutes_is_pushed_once_by_name_and_by_default_nothing_is_pressed_or_reset(w):
    me = os.getpid()
    _stalled(w, me, name="Thies")
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 400, 689)
    assert not w.notified()                                                               # 599 s: not yet
    _run_to(w, 690, 750, 810, 1000)
    pushes = w.notified()
    assert len(pushes) == 1 and "job falhou" in pushes[0] and "Thies" in pushes[0] and "10 min" in pushes[0] and "off" in pushes[0]
    assert "rc-limit-stalled" in w.state()["alerts"] and w.state()["banner_watch"]["pids"][str(me)]["stalled"] == w.now + 690
    assert w.keys() == [] and w.gc_calls() == []                                          # not a key, not even a `gc session list`
    assert not secrets_in(w.log() + (w.d / "crew_state.json").read_text() + "".join(pushes), w)


def test_the_banner_watch_runs_even_when_there_is_no_tmux_to_ask_and_says_so(w, monkeypatch):
    _stalled(w, os.getpid())
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    monkeypatch.setenv("FAKE_TMUX_DOWN", "1")
    _run_to(w, 400, 700, 1000)
    assert not w.notified() and "cannot tell" in w.log() and "banner_watch" in w.state()   # nothing seen = nothing claimed


def test_an_old_message_with_work_after_it_is_not_watched_at_all(w):
    _stalled(w, os.getpid(), text=OLD_MESSAGE_THEN_WORK)
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 400, 700, 1000)
    assert "banner_watch" not in w.state() and not w.notified() and w.keys() == []


def test_a_layout_that_was_never_measured_stays_cannot_tell_and_unwatched(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    monkeypatch.setenv("GC_CREW_RESET", "1")
    _stalled(w, os.getpid(), text=BANNER_ONLY)
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 400, 700, 1000)
    assert "banner_watch" not in w.state() and not w.notified() and w.keys() == [] and w.gc_calls() == []


def test_the_message_leaving_the_screen_ends_the_watch(w):
    me = os.getpid()
    _stalled(w, me)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.pane_set("%5", text=NO_MESSAGE)
    w.run(at=w.now + 150)
    assert "banner_watch" not in w.state() and "left the limit message" in w.log() and not w.notified()


def test_work_after_the_message_ends_the_watch_without_a_push(w):
    _stalled(w, os.getpid())
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.pane_set("%5", text=OLD_MESSAGE_THEN_WORK)
    _run_to(w, 150, 800)
    assert "banner_watch" not in w.state() and not w.notified()


def test_when_the_modal_opens_on_a_watched_session_it_moves_to_the_limit_watch(w):
    me = os.getpid()
    _stalled(w, me)
    _switch_crypto_to_amb(w)
    w.run(at=w.now + 90)
    w.pane_set("%5", text=LIMIT_MODAL)
    w.run(at=w.now + 150)
    st = w.state()
    assert "banner_watch" not in st and str(me) in st["limit_watch"]["pids"]


def test_a_session_that_ended_is_dropped_from_the_banner_watch(w):
    b = subprocess.Popen(["sleep", "60"])
    try:
        _stalled(w, b.pid)
        _switch_crypto_to_amb(w)
        w.run(at=w.now + 90)
    finally:
        b.kill()
        b.wait()
    w.run(at=w.now + 150)
    assert "banner_watch" not in w.state() and "ended on its own" in w.log()


def test_the_banner_watch_is_dropped_after_an_hour_and_the_push_stands(w):
    _stalled(w, os.getpid())
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 700)
    assert len(w.notified()) == 1
    _run_to(w, 90 + crew.BANNER_WATCH_S + 60)
    assert "banner_watch" not in w.state() and "the watch is dropped" in w.log() and len(w.notified()) == 1


def test_a_banner_watch_record_that_cannot_be_read_is_dropped_and_the_switch_still_happens(w):
    (w.d / "crew_state.json").write_text(json.dumps({"banner_watch": "garbage"}))
    _switch_crypto_to_amb(w)
    assert "banner_watch record in the state cannot be read" in w.log()
    assert w.state()["last_switch"]["to"] == EMAIL["amb"] and "banner_watch" not in w.state()


def test_a_bug_in_the_banner_watch_does_not_cost_the_switch(w, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("bug")
    monkeypatch.setattr(crew, "banner_last", boom)
    _stalled(w, os.getpid())
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 150)
    assert w.state()["last_switch"]["to"] == EMAIL["amb"] and "RuntimeError" in w.log() and not w.notified()


# ── the last rung: gc session reset (opt-in, OFF, conversation NOT preserved) ──────────────────────────────────
def _armed_stalled(w, monkeypatch, *, reset="1", **kw):
    monkeypatch.setenv("GC_CREW_RESET", reset)
    me = os.getpid()
    _stalled(w, me, **kw)
    w.gc_sessions(("gh-050", "gastown__mayor"), ("ga-1ioaom", "dog-ga1ioaom"))
    _switch_crypto_to_amb(w)
    return me


def _city_args(w):
    return ["--city", str(w.d / "city")]


def test_armed_a_session_stopped_for_ten_minutes_is_reset_once_and_the_push_says_the_conversation_is_lost(w, monkeypatch):
    me = _armed_stalled(w, monkeypatch)
    _run_to(w, 90, 400, 689)
    assert w.gc_calls() == [] and w.keys() == []
    _run_to(w, 690)
    assert w.gc_calls() == [_city_args(w) + ["session", "list", "--json"], _city_args(w) + ["session", "reset", "gh-050"]]
    assert w.keys() == []                                                                 # the reset is not a key either
    msgs = " | ".join(w.notified())
    assert "reset" in msgs and "NOT preserved" in msgs and "Mayor" in msgs
    assert str(me) not in w.state().get("banner_watch", {}).get("pids", {})
    _run_to(w, 750, 900, 2000)
    assert len(w.gc_calls()) == 2                                                         # once, never again
    assert not secrets_in(w.log() + (w.d / "crew_state.json").read_text() + msgs, w)


def test_unarmed_the_reset_is_not_even_looked_up(w, monkeypatch):
    _armed_stalled(w, monkeypatch, reset="0")
    _run_to(w, 90, 690, 2000)
    assert w.gc_calls() == [] and len(w.notified()) == 1 and "rc-limit-stalled" in w.state()["alerts"]


def test_the_reset_knob_the_env_beats_the_file_and_off_is_the_default(w, monkeypatch):
    assert crew.reset_armed() is False
    (w.d / "city" / ".gc" / "crew-reset-on").write_text("")
    assert crew.reset_armed() is True
    monkeypatch.setenv("GC_CREW_RESET", "0")
    assert crew.reset_armed() is False
    (w.d / "city" / ".gc" / "crew-reset-on").unlink()
    monkeypatch.setenv("GC_CREW_RESET", "1")
    assert crew.reset_armed() is True
    monkeypatch.setenv("GC_CREW_RESET", "maybe")
    assert crew.reset_armed() is False


def test_arming_the_escape_does_not_arm_the_reset(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    (w.d / "city" / ".gc" / "crew-unstick-on").write_text("")
    _armed_stalled(w, monkeypatch, reset="0")
    _run_to(w, 90, 690, 2000)
    assert w.gc_calls() == [] and w.keys() == [] and crew.reset_armed() is False


def _v_transcript_later(w, me):
    _transcript(w, "Mayor", me, "later")


def _v_transcript_before_the_switch(w, me):
    _transcript(w, "Mayor", me, "before")


def _v_transcript_undated(w, me):
    _transcript(w, "Mayor", me, "undated")


def _v_transcript_missing(w, me):
    _transcript(w, "Mayor", me, None)


def _v_transcript_garbage(w, me):
    _transcript(w, "Mayor", me, "garbage")


def _v_busy(w, me):
    f = w.d / "sessions" / f"{me}.json"
    f.write_text(json.dumps({**json.loads(f.read_text()), "status": "busy"}))


def _v_no_status(w, me):
    f = w.d / "sessions" / f"{me}.json"
    d = json.loads(f.read_text())
    d.pop("status")
    f.write_text(json.dumps(d))


def _v_exhausted(w, me):
    w.decide("amb", exhausted=["amb"])


def _v_pane_changed_at_the_key(w, me):
    w.pane_set("%5", captures=0, flip_after=1, flip_text=STALLED_TYPING)


def _v_no_gc_match(w, me):
    w.gc_sessions(("ga-1ioaom", "dog-ga1ioaom"))


def _v_two_gc_matches(w, me):
    w.gc_sessions(("gh-050", "gastown__mayor"), ("gh-051", "gastown__mayor"))


def _v_gc_list_fails(w, me):
    os.environ["FAKE_GC_LIST_FAIL"] = "1"


def _v_default_item_changed(w, me):
    w.default("crypto", blob("crypto", rt="crypto-again"))


def _v_not_this_process(w, me):
    f = w.d / "sessions" / f"{me}.json"
    f.write_text(json.dumps({**json.loads(f.read_text()), "tmux": "gastown__mayor:@3.%9"}))     # %9 is nobody's pane in the fake


@pytest.mark.parametrize("variant,why", [
    (_v_transcript_later, "does not confirm"),          # the message is old: work came after it
    (_v_transcript_before_the_switch, "not dated after the switch"),   # idle on an old message since before the switch: nothing is wrong
    (_v_transcript_undated, "not dated after the switch"),             # cannot tell when = no
    (_v_transcript_missing, "does not confirm"),         # cannot tell = no
    (_v_transcript_garbage, "does not confirm"),
    (_v_busy, "not idle"),                               # the session file says it is working
    (_v_no_status, "not idle"),
    (_v_exhausted, "itself registered exhausted"),
    (_v_pane_changed_at_the_key, "not stopped any more"),
    (_v_no_gc_match, "no gc session"),
    (_v_two_gc_matches, "more than one gc session"),
    (_v_gc_list_fails, "could not list"),
    (_v_default_item_changed, "cannot tell that the default item holds"),
    (_v_not_this_process, "another pane"),
], ids=lambda v: v.__name__[3:] if callable(v) else None)
def test_armed_but_one_guard_says_no_and_nothing_is_reset(w, monkeypatch, variant, why):
    me = _armed_stalled(w, monkeypatch)
    _run_to(w, 90, 400)
    variant(w, me)
    try:
        _run_to(w, 690)
    finally:
        os.environ.pop("FAKE_GC_LIST_FAIL", None)
    assert not any(c[-3:-1] == ["session", "reset"] for c in w.gc_calls()), w.gc_calls()
    assert why in w.log(), w.log()[-800:]
    assert "reset" not in " ".join(w.notified()).replace("gc session reset", "")           # the stall push may name the command; no "was reset"


def test_a_reset_that_gc_refuses_is_pushed_and_not_retried(w, monkeypatch):
    me = _armed_stalled(w, monkeypatch)
    monkeypatch.setenv("FAKE_GC_RESET_FAIL", "1")
    _run_to(w, 90, 690, 750, 900)
    resets = [c for c in w.gc_calls() if "reset" in c]
    assert len(resets) == 1 and any("could not be reset" in n for n in w.notified())
    assert "rc-limit-reset-failed" in w.state()["alerts"]


def test_dry_run_says_it_would_reset_and_runs_nothing(w, monkeypatch, capsys):
    _armed_stalled(w, monkeypatch)
    _run_to(w, 90)
    w.run(dry=True, at=w.now + 690)
    assert w.gc_calls() == [] and w.keys() == [] and w.notified() == []
    assert f"DRY-RUN would run gc session reset for Mayor ({os.getpid()})" in capsys.readouterr().err


def test_the_reset_needs_the_process_to_be_provably_the_same(w, monkeypatch):
    me = _armed_stalled(w, monkeypatch)
    _run_to(w, 90)
    st = w.state()
    st["banner_watch"]["pids"][str(me)]["start"] = ""
    (w.d / "crew_state.json").write_text(json.dumps(st))
    _run_to(w, 690)
    assert not [c for c in w.gc_calls() if "reset" in c] and "no start time" in w.log()


def test_the_modal_whose_escapes_failed_gets_the_reset_after_ten_minutes_only_when_both_are_armed(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    monkeypatch.setenv("GC_CREW_RESET", "1")
    me = os.getpid()
    _rc(w, me, "%5", LIMIT_MODAL)
    d = json.loads((w.d / "sessions" / f"{me}.json").read_text())
    d.update(tmux="gastown__mayor:@3.%5")
    (w.d / "sessions" / f"{me}.json").write_text(json.dumps(d))
    w.gc_sessions(("gh-050", "gastown__mayor"))
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 150, 215, 280)                                                         # two Escapes, neither takes
    assert len(w.keys()) == 2 and w.gc_calls() == []
    _run_to(w, 400, 600)
    assert w.gc_calls() == []                                                             # found at +90: not ten minutes yet
    _run_to(w, 700)
    assert [c[-2:] for c in w.gc_calls() if "reset" in c] == [["reset", "gh-050"]]
    assert "limit_watch" not in w.state() or str(me) not in w.state()["limit_watch"]["pids"]


def test_the_modal_whose_escapes_failed_is_not_reset_when_only_the_escape_is_armed(w, monkeypatch):
    monkeypatch.setenv("GC_CREW_UNSTICK", "1")
    me = os.getpid()
    _rc(w, me, "%5", LIMIT_MODAL)
    w.gc_sessions(("gh-050", "gastown__mayor"))
    _switch_crypto_to_amb(w)
    _run_to(w, 90, 150, 215, 280, 700)
    assert len(w.keys()) == 2 and w.gc_calls() == []


# ── the reads of the last rung, failing: every one lands on "unknown"/"no session", never on a reset ─────────────
def test_a_transcript_that_is_absent_unreadable_or_corrupt_says_unknown_and_a_real_one_says_limit(w):
    sf = {"sessionId": "sess-7-0000", "cwd": "/work/Mayor"}
    assert crew.transcript_says(sf) == ("unknown", None)                                   # no such file
    _transcript(w, "Mayor", 7, "garbage")
    assert crew.transcript_says(sf) == ("unknown", None)                                   # the tail is not JSON
    proj = w.d / "projects" / re.sub(r"[^A-Za-z0-9]", "-", "/work/Mayor")
    (proj / "sess-7-0000.jsonl").unlink()
    (proj / "sess-7-0000.jsonl").mkdir()
    assert crew.transcript_says(sf) == ("unknown", None)                                   # there, but it cannot be read as a file
    assert crew.transcript_says({"sessionId": "../escape", "cwd": "/work/Mayor"}) == ("unknown", None)
    assert crew.transcript_says({}) == ("unknown", None)
    (proj / "sess-7-0000.jsonl").rmdir()
    _transcript(w, "Mayor", 7, "limit")
    what, when = crew.transcript_says(sf)
    assert what == "limit" and abs(when - (w.now + 30)) < 2


def test_a_gc_that_cannot_run_times_out_or_answers_garbage_names_no_session(w, monkeypatch):
    field = "gastown__mayor:@3.%5"
    w.gc_sessions(("gh-050", "gastown__mayor"))
    assert crew.gc_session_id(field) == ("gh-050", "")                                      # the control: the fake answers
    for bad in ("{not json", '{"sessions": "x"}', "[]"):
        (w.d / "gcd" / "sessions.json").write_text(bad)
        sid, why = crew.gc_session_id(field)
        assert sid is None and "could not list" in why, bad
    def cannot_start(*a, **k):
        raise OSError("gc: not found")
    def too_slow(*a, **k):
        raise subprocess.TimeoutExpired("gc", 1)
    for boom in (cannot_start, too_slow):
        with monkeypatch.context() as m:
            m.setattr(crew.subprocess, "run", boom)
            assert crew.gc_run(["session", "list", "--json"]) == (None, "")
            sid, why = crew.gc_session_id(field)
            assert sid is None and "could not list" in why
    with monkeypatch.context() as m:
        m.setenv("CLAUDE_CREW_GC", str(w.d / "no-such-gc"))
        assert crew.gc_run(["session", "list", "--json"]) == (None, "")                      # no gc binary at all
