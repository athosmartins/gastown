"""ga-qdtmq2 — claude-crew-account.py: the Mayor's and the crews' Claude account follows the pool decision, LIVE.

Every test runs against a FAKE `security` (a json store; it logs every argv so we can prove no secret rides on a command
line) and a loopback profile server. Nothing here touches the real Keychain or the network.

The harness PROVES that last sentence instead of trusting it (the Mayor's finding on this branch: the first version leaked into
production - `CLAUDE_CREW_NOTIFY` falls back to `shutil.which('notify')` and the log follows the caller's `GC_CITY_PATH`):
  * `_pin_env` (autouse, every test) points notify / security / the city / the state at sentinels and tmp paths, so even a test
    that forgets to build a `World` cannot reach the real ones;
  * `_nothing_real_was_touched` (autouse, once per session) snapshots the real log / state / lock and asserts at the end that
    they are unchanged and that no sentinel was ever executed;
  * `test_the_real_script_run_from_an_empty_environment...` runs the script as launchd would (env -i) under both interpreters.
"""
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
    cities = {c for c in (_REAL_ENV.get("GC_CITY_PATH"), str(Path.home() / "gt" / ".gascity-gastown-hq")) if c}
    out = [Path(crew.DEFAULT_STATE)]          # the pool's decision file is written by the live pool daemon: not ours to watch
    for c in sorted(cities):
        out += [Path(c) / ".gc" / "logs" / "claude-crew-account.log", Path(c) / ".gc" / "claude-crew-account.lock"]
    return out


def _snap():
    r = {}
    for p in _real_files():
        try:
            st = p.stat()
            r[str(p)] = (st.st_size, st.st_mtime_ns)
        except OSError:
            r[str(p)] = None
    return r


@pytest.fixture(scope="session", autouse=True)
def _nothing_real_was_touched(tmp_path_factory):
    guard = tmp_path_factory.mktemp("guard")
    (guard / "bin").mkdir()
    hits = guard / "hits.log"
    _sentinel(guard / "notify", hits)
    _sentinel(guard / "security", hits)
    _sentinel(guard / "bin" / "notify", hits)
    _sentinel(guard / "bin" / "security", hits)
    _GUARD.update(dir=guard, hits=hits)
    before = _snap()
    yield
    assert not hits.exists(), "a test reached the REAL notify/security (sentinel executed):\n" + hits.read_text()
    assert _snap() == before, "a test touched the REAL claude-crew-account log/state/lock"


@pytest.fixture(autouse=True)
def _pin_env(monkeypatch, tmp_path):
    g = _GUARD["dir"]
    for k, v in {"CLAUDE_CREW_NOTIFY": g / "notify", "CLAUDE_CREW_SECURITY": g / "security",
                 "GC_CITY_PATH": tmp_path / "pinned-city", "CLAUDE_CREW_STATE": tmp_path / "pinned-state.json",
                 "CLAUDE_CREW_DECISION": tmp_path / "pinned-decision.json",
                 "CLAUDE_CREW_ACCOUNTS_DIR": tmp_path / "pinned-accts", "HOME": tmp_path / "pinned-home"}.items():
        monkeypatch.setenv(k, str(v))
    monkeypatch.setenv("PATH", f"{g / 'bin'}:/usr/bin:/bin")        # `which notify` / bare `security` find a sentinel, never the real one


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
        for name, body in (("security", FAKE_SECURITY), ("notify", NOTIFY)):
            p = self.d / name
            p.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))   # not the PATH's python: PATH is pinned to the sentinels
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.d / "city" / ".gc" / "logs").mkdir(parents=True)
        self.now = time.time()
        for k, v in {
            "FAKE_SEC_DIR": str(self.d), "CLAUDE_CREW_SECURITY": str(self.d / "security"),
            "CLAUDE_CREW_NOTIFY": str(self.d / "notify"), "CLAUDE_CREW_STATE": str(self.d / "crew_state.json"),
            "CLAUDE_CREW_DECISION": str(self.d / "pool_decision.json"),
            "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
            "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(self.now),
        }.items():
            monkeypatch.setenv(k, v)
        for k in ("GC_CREW_ACCOUNT", "CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL", "FAKE_SEC_WFAIL", "FAKE_SEC_DROP", "FAKE_NOTIFY_FAIL"):
            monkeypatch.delenv(k, raising=False)
        self.mp = monkeypatch
        # the world must be sealed: every seam inside this tmp dir, none of them a sentinel
        for fn in (crew.security_bin, crew.state_path, crew.decision_path):
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
         "CLAUDE_CREW_ACCOUNTS_DIR", "CLAUDE_CREW_USER", "GC_CITY_PATH", "CLAUDE_CREW_PROFILE_URL",
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
