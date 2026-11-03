"""ga-xoe5ao.5 — claude-login-renew.py: the Claude logins of the mini are renewed by themselves (T-7 days + outage), through gmail-totp.

No network, no real browser, no real Keychain, no real phone: `security` is a json store, `claude` is a fake that asks "the browser" (`open <url>`)
and only finishes when the fake driver says the callback happened, the driver is a fake that prints a verdict, the profile is a loopback server.

What this proves, in the words of the bead:
  * the trigger: the forecast (best login ends within 7 days) and the outage (no full login anywhere while the default has none);
  * the account that HOLDS the default is never relogged by the forecast (its rotation keeps it alive, and a fresh login might cost it its token);
  * the attempt: `claude auth login --email <e>` in the account's OWN config dir, the OAuth URL captured by a PATH shim (the real browser of Athos is never opened)
    and handed to the driver on STDIN (never argv, never log, never state, never a push), the new login judged by what is in the Keychain item and by whose it is;
  * anti-bot puzzle / Google asking for what this job does not do / a browser signed in as another account: NOT circumvented, no retry, the account is marked
    "inviável por automação" and Athos gets ONE push with the exact step; a login that landed wrong is put back as it was;
  * the third state everywhere: an item that cannot be read is never overwritten; a driver that hangs or lies is a failed try, not a success.
"""
import contextlib
import copy
import hashlib
import http.server
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve()
ASSETS = HERE.parents[1] / "packs" / "town-deltas" / "assets" / "scripts"
SCRIPT = ASSETS / "claude-login-renew.py"
spec = importlib.util.spec_from_file_location("claude_login_renew_under_test", SCRIPT)
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)
crew = renew.C

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
            sys.exit(1)
        store[m.group(2)] = {"acct": m.group(1), "secret": bytes.fromhex(m.group(3)).decode()}
        with open(os.path.join(d, "writes.log"), "a") as f:
            f.write(m.group(2) + "\n")
    json.dump(store, open(store_p, "w"))
    sys.exit(0)
if a and a[0] == "delete-generic-password":
    svc = a[a.index("-s") + 1]
    if svc not in store:
        sys.exit(44)
    del store[svc]
    json.dump(store, open(store_p, "w"))
    with open(os.path.join(d, "deletes.log"), "a") as f:
        f.write(svc + "\n")
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

# The fake CLI: asks the "browser" through `open` (found on PATH - the job's shim must be first), then waits for the driver's callback.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import hashlib, json, os, subprocess, sys, time
d = os.environ["FAKE_SEC_DIR"]
cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
with open(os.path.join(d, "claude.log"), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "cfg": cfg, "path0": os.environ["PATH"].split(":")[0]}) + "\n")
mode = os.environ.get("FAKE_CLAUDE_MODE", "")
if mode == "fail":
    sys.exit(1)
URL = "https://claude.ai/oauth/authorize?client_id=x&state=SECRETSTATE-0123456789&code_challenge=CHALLENGE-abcdef&redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcallback"
if mode != "noopen":
    subprocess.run(["open", URL], check=False)
    print("If the browser did not open, visit: " + URL)       # what the real CLI prints: nobody may copy it into a log
if mode == "noopen":
    sys.exit(0)
cb = os.path.join(d, "callback")
end = time.time() + float(os.environ.get("FAKE_CLAUDE_WAIT", "20"))
while not os.path.exists(cb):
    if time.time() > end:
        sys.exit(1)
    time.sleep(0.05)
if mode == "late_fail":
    sys.exit(1)                                          # the browser dance happened, the CLI still failed
if mode == "hang":
    time.sleep(120)
svc = "Claude Code-credentials-" + hashlib.sha256(os.path.abspath(cfg).encode()).hexdigest()[:8]
store_p = os.path.join(d, "store.json")
store = json.load(open(store_p)) if os.path.exists(store_p) else {}
store[svc] = {"acct": "athos", "secret": os.environ["FAKE_CLAUDE_BLOB"]}
json.dump(store, open(store_p, "w"))
sys.exit(0)
'''

FAKE_DRIVER = r'''#!/usr/bin/env python3
import json, os, sys, time
d = os.environ["FAKE_SEC_DIR"]
url = sys.stdin.read()
with open(os.path.join(d, "driver.log"), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "stdin_len": len(url), "stdin_has_url": url.startswith("https://claude.ai/")}) + "\n")
v = os.environ.get("FAKE_DRIVER_VERDICT", "ok")
if v == "hang":
    time.sleep(120)
print("some playwright chatter that is not json")
if v == "garbage":
    print("not json at all")
    sys.exit(0)
if v == "ok":
    open(os.path.join(d, "callback"), "w").write("x")
print(json.dumps({"verdict": v, "step": "at claude.ai/oauth/authorize"}))
'''

NOTIFY = ("#!/bin/sh\necho \"$@\" >> \"$FAKE_SEC_DIR/notify.log\"\necho \"$NOTIFY_STRICT_EXIT/$NOTIFY_FORCE_PUSH\" >> \"$FAKE_SEC_DIR/notify.env\"\n"
          "exit \"${FAKE_NOTIFY_RC:-0}\"\n")
GC = "#!/bin/sh\necho \"$@\" >> \"$FAKE_SEC_DIR/gc.log\"\nexit 0\n"
EMAIL = {"crypto": "athoscrypto@gmail.com", "amb": "throw.away.amb@gmail.com", "b85": "athosb85@gmail.com",
         "terr": "terrenos.incorporacoes@gmail.com", "martins": "athosmartins@gmail.com"}
T0 = float(int(time.time()))              # a WHOLE second: blob() writes milliseconds, so "exactly 7 days" really is 604800.000 s and the <= edge can be pinned
DAY = 86400


def blob(tag, *, rexp_days=29.0, scopes=None, acc_hours=7.0, refresh=True):
    o = {"accessToken": f"sk-ant-oat01-{tag}-acc", "expiresAt": int((T0 + acc_hours * 3600) * 1000),
         "scopes": scopes if scopes is not None else ["user:inference", "user:profile", "user:sessions:claude_code"], "subscriptionType": "max"}
    if refresh:
        o["refreshToken"] = f"sk-ant-ort01-{tag}-ref"
        o["refreshTokenExpiresAt"] = int((T0 + rexp_days * DAY) * 1000)
    return {"claudeAiOauth": o}


_GUARD: dict = {}


def _sentinel(path: Path, hits: Path) -> None:
    path.write_text(f'#!/bin/sh\necho "$0 $*" >> "{hits}"\nexit 99\n')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture(scope="session", autouse=True)
def _nothing_real_was_touched(tmp_path_factory):
    guard = tmp_path_factory.mktemp("guard")
    (guard / "bin").mkdir()
    hits = guard / "hits.log"
    for n in ("notify", "security", "gc", "claude", "open", "xdg-open", "gmail-totp"):
        _sentinel(guard / n, hits)
        _sentinel(guard / "bin" / n, hits)
    _GUARD.update(dir=guard, hits=hits)
    yield
    assert not hits.exists(), "a test reached a REAL notify/security/gc/claude/open/gmail-totp (sentinel executed):\n" + hits.read_text()


@pytest.fixture(autouse=True)
def _pin_env(monkeypatch, tmp_path):
    g = _GUARD["dir"]
    for k, v in {"CLAUDE_CREW_NOTIFY": g / "notify", "CLAUDE_CREW_SECURITY": g / "security", "CLAUDE_CREW_GC": g / "gc",
                 "CLAUDE_RENEW_CLAUDE": g / "claude", "CLAUDE_RENEW_DRIVER": json.dumps([str(g / "gmail-totp")]),
                 "GC_CITY_PATH": tmp_path / "pinned-city", "CLAUDE_CREW_STATE": tmp_path / "pinned-crew-state.json",
                 "CLAUDE_RENEW_STATE": tmp_path / "pinned-renew-state.json", "CLAUDE_CREW_DECISION": tmp_path / "pinned-decision.json",
                 "CLAUDE_CREW_ACCOUNTS_DIR": tmp_path / "pinned-accts", "HOME": tmp_path / "pinned-home"}.items():
        monkeypatch.setenv(k, str(v))
    monkeypatch.setenv("PATH", f"{g / 'bin'}:/usr/bin:/bin")


class World:
    def __init__(self, tmp, monkeypatch):
        self.d = tmp / "world"
        self.d.mkdir()
        self.tokens = {}
        w = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                email = w.tokens.get((self.headers.get("Authorization") or "").replace("Bearer ", ""))
                self.send_response(200 if email else 401)
                self.end_headers()
                if email:
                    self.wfile.write(json.dumps({"account": {"email": email}}).encode())

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        for name, body in (("security", FAKE_SECURITY), ("notify", NOTIFY), ("claude", FAKE_CLAUDE), ("driver", FAKE_DRIVER), ("gc", GC)):
            p = self.d / name
            p.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.d / "city" / ".gc" / "logs").mkdir(parents=True)
        self.now = T0
        for k, v in {"FAKE_SEC_DIR": str(self.d), "CLAUDE_CREW_SECURITY": str(self.d / "security"), "CLAUDE_CREW_NOTIFY": str(self.d / "notify"),
                     "CLAUDE_CREW_GC": str(self.d / "gc"), "CLAUDE_RENEW_CLAUDE": str(self.d / "claude"),
                     "CLAUDE_RENEW_DRIVER": json.dumps([str(self.d / "driver"), "drive"]), "CLAUDE_CREW_STATE": str(self.d / "crew_state.json"),
                     "CLAUDE_RENEW_STATE": str(self.d / "renew_state.json"), "CLAUDE_CREW_DECISION": str(self.d / "pool_decision.json"),
                     "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
                     "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(self.now)}.items():
            monkeypatch.setenv(k, v)
        for k in ("GC_LOGIN_RENEW", "CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL", "FAKE_SEC_WFAIL", "FAKE_CLAUDE_MODE", "FAKE_CLAUDE_WAIT", "FAKE_DRIVER_VERDICT",
                  "FAKE_NOTIFY_RC", "FAKE_CLAUDE_BLOB"):
            monkeypatch.delenv(k, raising=False)
        self.mp = monkeypatch
        assert str(crew.security_bin()).startswith(str(self.d)) and os.environ["CLAUDE_RENEW_STATE"].startswith(str(self.d))
        assert os.environ["CLAUDE_RENEW_CLAUDE"].startswith(str(self.d)) and str(crew.city()).startswith(str(self.d))

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

    def svc(self, key):
        return crew.dir_service(str(self.d / "accts" / {"crypto": "athoscrypto", "amb": "throw.away.amb", "b85": "athosb85", "terr": "terrenos"}[key]))

    def own(self, key, b):
        self.put(self.svc(key), copy.deepcopy(b))

    def default(self, key, b):
        self.put(crew.DEFAULT_SERVICE, b)
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[key]

    def crew_state(self, **kw):
        (self.d / "crew_state.json").write_text(json.dumps(kw))

    def decide(self, key):
        (self.d / "pool_decision.json").write_text(json.dumps({"current": EMAIL[key], "updated": crew._iso(self.now), "schema": 1, "exhausted": {}}))

    def login_will_be(self, key, b, *, owner=None):
        """What the fake CLI stores when the browser dance works: `b`, whose access token the profile says belongs to `owner` (default: `key`)."""
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[owner or key]
        self.mp.setenv("FAKE_CLAUDE_BLOB", json.dumps(b))

    def run(self, *argv, at=None, **kw):
        if at is not None:
            self.mp.setenv("CLAUDE_CREW_NOW", str(at))
        return renew.run_once(**kw)

    def state(self):
        p = self.d / "renew_state.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def log(self):
        p = self.d / "city" / ".gc" / "logs" / "claude-login-renew.log"
        return p.read_text() if p.exists() else ""

    def pushes(self):
        p = self.d / "notify.log"
        return p.read_text().splitlines() if p.exists() else []

    def claude_calls(self):
        p = self.d / "claude.log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def driver_calls(self):
        p = self.d / "driver.log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def everything_written(self):
        """Every byte this job left behind or sent anywhere, for the 'no secret, no URL' scans."""
        parts = [self.log(), json.dumps(self.state()), "\n".join(self.pushes()), (self.d / "argv.log").read_text() if (self.d / "argv.log").exists() else "",
                 json.dumps(self.claude_calls()), json.dumps(self.driver_calls())]
        return "\n".join(parts)


@pytest.fixture
def w(tmp_path, monkeypatch):
    return World(tmp_path, monkeypatch)


def fps(b):
    o = b["claudeAiOauth"]
    return crew.fp(o["accessToken"]), crew.fp(o["refreshToken"])


# ── the trigger ────────────────────────────────────────────────────────────────
def test_a_login_ending_within_a_week_is_renewed_in_the_account_own_dir_and_the_proof_is_recorded(w):
    old, new = blob("b85-old", rexp_days=5.0), blob("b85-new", rexp_days=30.0)
    w.own("b85", old)
    w.login_will_be("b85", new)
    assert w.run() == 0
    call = w.claude_calls()
    assert [c["argv"] for c in call] == [["auth", "login", "--email", EMAIL["b85"]]]
    assert call[0]["cfg"] == str(w.d / "accts" / "athosb85")                      # the account's OWN dir: the switch job finds the item the next minute
    assert fps(w.get(w.svc("b85"))) == fps(new)
    rec = w.state()["accounts"][EMAIL["b85"]]["renewed"]
    assert rec["before"] == {"afp": fps(old)[0], "rfp": fps(old)[1], "rexp": crew._iso(T0 + 5 * DAY)}
    assert rec["after"] == {"afp": fps(new)[0], "rfp": fps(new)[1], "rexp": crew._iso(T0 + 30 * DAY)}
    assert rec["svc"] == w.svc("b85") and rec["reason"] == "forecast" and rec["at"] == T0
    assert w.pushes() == []                                                       # good news is in the log and the state, not on the phone
    assert "renewed" in w.log() and EMAIL["b85"] in w.log()


def test_a_login_with_two_weeks_left_is_left_alone(w):
    w.own("b85", blob("b85", rexp_days=14.0))
    assert w.run() == 0
    assert w.claude_calls() == [] and w.driver_calls() == []


def test_the_forecast_edge_is_exactly_seven_days(w):
    w.own("b85", blob("b85-edge", rexp_days=7.0))
    w.own("terr", blob("terr-edge", rexp_days=7.0 + 1 / 1440))
    w.login_will_be("b85", blob("b85-edge-new"))
    w.run()
    assert [c["cfg"] for c in w.claude_calls()] == [str(w.d / "accts" / "athosb85")]


def test_an_already_expired_login_is_due_too(w):
    w.own("b85", blob("b85-dead", rexp_days=-2.0))
    w.login_will_be("b85", blob("b85-fresh"))
    w.run()
    assert fps(w.get(w.svc("b85"))) == fps(blob("b85-fresh"))


def test_the_best_login_of_the_account_decides_not_the_worst(w):
    w.own("b85", blob("b85-short", rexp_days=3.0))
    w.put(crew.reserve_service(EMAIL["b85"]), blob("b85-reserve", rexp_days=20.0))
    assert w.run() == 0
    assert w.claude_calls() == []


def test_the_account_that_holds_the_default_is_not_relogged_by_the_forecast(w):
    w.default("crypto", blob("crypto-live", rexp_days=25.0))
    w.crew_state(current=EMAIL["crypto"])
    w.own("crypto", blob("crypto-stored", rexp_days=2.0))                         # its stored copy ages: the default's rotation is what keeps the account alive
    w.run()
    assert w.claude_calls() == []
    assert "holds the default" in w.log()


def test_an_account_with_no_config_dir_is_never_attempted(w):
    w.put("Claude Code-credentials-BACKUP-athosmartins-20261004", blob("martins", rexp_days=1.0))
    w.run()
    assert w.claude_calls() == []


def test_an_item_that_cannot_be_read_is_not_judged_and_never_overwritten(w):
    w.own("b85", blob("b85", rexp_days=2.0))
    w.mp.setenv("FAKE_SEC_FAIL", w.svc("b85"))
    w.run()
    assert w.claude_calls() == [] and w.driver_calls() == []
    assert w.state().get("accounts", {}).get(EMAIL["b85"]) in (None, {})
    assert "cannot" in w.log() or "could not" in w.log()


def test_one_account_per_run_the_nearest_to_its_end_first(w):
    w.own("b85", blob("b85", rexp_days=5.0))
    w.own("terr", blob("terr", rexp_days=2.0))
    w.login_will_be("terr", blob("terr-new"))
    w.run()
    assert [c["cfg"] for c in w.claude_calls()] == [str(w.d / "accts" / "terrenos")]


# ── the outage ──────────────────────────────────────────────────────────────────
def _outage(w, since_ago=700):
    w.crew_state(no_login={"since": T0 - since_ago, "why": "no access token", "last_bad": T0, "heals": True})


def test_an_outage_with_no_full_login_anywhere_relogs_the_pool_pick_first(w):
    _outage(w)
    w.decide("terr")
    w.login_will_be("terr", blob("terr-new"))
    w.run()
    assert [c["cfg"] for c in w.claude_calls()] == [str(w.d / "accts" / "terrenos")]
    assert w.state()["accounts"][EMAIL["terr"]]["renewed"]["reason"] == "outage"


def test_an_outage_younger_than_ten_minutes_waits(w):
    _outage(w, since_ago=599)
    w.decide("terr")
    w.run()
    assert w.claude_calls() == []


def test_an_outage_with_a_stored_full_login_is_the_crew_jobs_to_heal_not_ours(w):
    _outage(w)
    w.decide("terr")
    w.own("b85", blob("b85", rexp_days=25.0))
    w.run()
    assert w.claude_calls() == []


def test_a_stored_login_the_crew_job_calls_dead_does_not_count_as_a_login(w):
    dead = blob("b85-dead", rexp_days=25.0)
    w.own("b85", dead)
    w.crew_state(no_login={"since": T0 - 700, "why": "no access token", "last_bad": T0, "heals": True},
                 burned={fps(dead)[1]: {"n": 2, "svc": w.svc("b85"), "target": EMAIL["b85"], "at": T0 - 100}})
    w.decide("b85")
    w.login_will_be("b85", blob("b85-fresh"))
    w.run()
    assert [c["cfg"] for c in w.claude_calls()] == [str(w.d / "accts" / "athosb85")]


# ── the attempt ─────────────────────────────────────────────────────────────────
def test_the_oauth_url_goes_to_the_driver_on_stdin_and_nowhere_else(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-new"))
    w.run()
    assert w.driver_calls() == [{"argv": ["drive"], "stdin_len": w.driver_calls()[0]["stdin_len"], "stdin_has_url": True}]
    assert w.driver_calls()[0]["stdin_len"] > 100
    everything = w.everything_written()
    for needle in ("SECRETSTATE", "CHALLENGE-abcdef", "oauth/authorize?", "sk-ant-"):
        assert needle not in everything, needle
    assert w.claude_calls()[0]["path0"] != str(_GUARD["dir"] / "bin")             # the PATH shim (`open`) was first: Athos's browser never opened
    assert not _GUARD["hits"].exists()


def test_no_secret_rides_on_a_command_line(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-new"))
    w.run()
    argv = (w.d / "argv.log").read_text()
    assert "sk-ant" not in argv and "refreshToken" not in argv
    assert w.get(w.svc("b85")) is not None


def test_the_shim_directory_does_not_outlive_the_attempt(w, tmp_path, monkeypatch):
    import tempfile
    (tmp_path / "tmpdir").mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "tmpdir"))
    w.own("b85", blob("b85", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-new"))
    w.run()
    assert list((tmp_path / "tmpdir").iterdir()) == []


def test_a_login_that_is_not_a_full_login_is_a_failed_try_and_the_old_item_comes_back_as_it_was(w):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.login_will_be("b85", blob("b85-nosession", scopes=["user:inference"]))
    w.run()
    assert w.get(w.svc("b85")) == old
    a = w.state()["accounts"][EMAIL["b85"]]
    assert a["tries"] == 1 and "renewed" not in a and a["last"]["verdict"] == "no_full_login"
    assert w.pushes() == []                                                       # a first failure is not news yet


def test_a_login_that_belongs_to_another_account_is_put_back_and_the_account_is_marked(w):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.login_will_be("b85", blob("crypto-by-mistake"), owner="crypto")
    w.run()
    assert w.get(w.svc("b85")) == old
    assert w.state()["accounts"][EMAIL["b85"]]["infeasible"]["verdict"] == "wrong_account"
    assert len(w.pushes()) == 1 and EMAIL["b85"] in w.pushes()[0]


def test_a_first_login_that_landed_on_the_wrong_account_is_removed_not_kept(w):
    w.login_will_be("b85", blob("crypto-by-mistake"), owner="crypto")
    _outage(w)
    w.decide("b85")
    w.run()
    assert w.get(w.svc("b85")) is None
    assert (w.d / "deletes.log").read_text().splitlines() == [w.svc("b85")]


def test_a_cli_that_exits_without_ever_asking_for_a_browser_is_a_failed_try(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "noopen")
    w.run()
    assert w.driver_calls() == []
    assert w.state()["accounts"][EMAIL["b85"]]["last"]["verdict"] == "no_browser_request"


# ── reads that fail: the third state is said out loud, never a silent verdict ───────────────────
@pytest.mark.parametrize("junk", [b"{not json", b"\xff\xfe\x00 not utf8", b"[1, 2]", b'"a string"', b"",
                                  b'{"accounts": [1]}', b'{"accounts": null}', b'{"accounts": {"x": "a string"}}', b'{"accounts": {"x": ["no"]}}'])
def test_a_state_file_that_is_corrupt_is_said_and_replaced_not_trusted_nor_fatal(w, junk):
    (w.d / "renew_state.json").write_bytes(junk)
    new = blob("b85-new", rexp_days=30.0)
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.login_will_be("b85", new)
    w.run()                                                                      # must not raise
    assert "unreadable" in w.log() and "empty state" in w.log()
    rec = w.state()["accounts"][EMAIL["b85"]]["renewed"]                         # rewritten as a valid object, and the run went on
    assert rec["after"]["rfp"] == fps(new)[1] and fps(w.get(w.svc("b85"))) == fps(new)


def test_a_state_path_that_cannot_be_read_is_said_and_the_run_goes_on_with_an_empty_state(w):
    (w.d / "renew_state.json").mkdir()                                           # read_bytes() -> IsADirectoryError (an OSError), not "missing"
    assert renew.load_state() == {}
    assert "unreadable" in w.log()


def test_a_state_file_that_is_simply_missing_is_a_first_run_and_says_nothing(w):
    assert not (w.d / "renew_state.json").exists()
    assert renew.load_state() == {}
    assert "unreadable" not in w.log()                                           # vazio is not falhou: no false alarm on the first run


def test_a_state_file_that_is_denied_to_us_is_said_and_never_taken_for_a_first_run(w, monkeypatch):
    (w.d / "renew_state.json").write_text('{"accounts": {"x": {"infeasible": {"verdict": "puzzle"}}}}')   # a mark that exists but cannot be read now

    def deny(self, *a, **k):
        raise PermissionError(13, "Permission denied")
    monkeypatch.setattr(Path, "read_bytes", deny)
    assert renew.load_state() == {}                                              # nothing is trusted from a file we could not read ...
    assert "unreadable" in w.log() and "marks and tries are lost" in w.log()      # ... and the loss is in the log, unlike a missing file (a first run)


def test_a_url_file_that_is_denied_to_us_while_the_cli_lives_never_yields_a_url(tmp_path, monkeypatch):
    class Cli:                                                                   # alive for two looks, then gone
        n = 0

        def poll(self):
            self.n += 1
            return None if self.n < 3 else 1
    (tmp_path / "url").write_text("https://claude.ai/oauth/authorize?x=1")       # the URL is there, but we are not allowed to read it

    def deny(self, *a, **k):
        raise PermissionError(13, "Permission denied")
    monkeypatch.setattr(Path, "read_text", deny)
    monkeypatch.setattr(renew.time, "sleep", lambda s: None)
    assert renew.wait_for_url(Cli(), tmp_path / "url") is None                   # a read that failed is "no URL yet", then a failed try - never a guessed URL


def test_a_url_file_that_cannot_be_read_while_the_cli_lives_is_no_url_not_a_crash(tmp_path, monkeypatch):
    class Dead:                                                                  # the CLI is gone, and the url path is a directory (OSError on read)
        def poll(self):
            return 1
    (tmp_path / "url").mkdir()
    monkeypatch.setattr(renew, "URL_WAIT_S", 5)
    assert renew.wait_for_url(Dead(), tmp_path / "url") is None                  # unreadable + dead CLI -> None (a failed try), never a URL it did not read
    assert renew.wait_for_url(Dead(), tmp_path / "never-written") is None        # missing + dead CLI -> the same


def test_a_cli_that_fails_after_the_driver_said_ok_is_a_failed_try(w):
    old = blob("b85", rexp_days=3.0)
    w.own("b85", old)
    w.mp.setenv("FAKE_CLAUDE_MODE", "late_fail")
    w.run()
    assert len(w.driver_calls()) == 1 and w.get(w.svc("b85")) == old
    a = w.state()["accounts"][EMAIL["b85"]]
    assert a["tries"] == 1 and a["last"]["verdict"] == "no_full_login"


def test_a_cli_that_never_finishes_is_killed_and_is_a_failed_try(w, monkeypatch):
    monkeypatch.setattr(renew, "CLI_WAIT_S", 1.0)
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "hang")
    t0 = time.time()
    w.run()
    assert time.time() - t0 < 30
    assert w.state()["accounts"][EMAIL["b85"]]["last"]["verdict"] in ("no_full_login", "cli_timeout")
    out = subprocess.run(["/bin/ps", "-axo", "command"], capture_output=True, text=True).stdout
    assert str(w.d / "claude") not in out


def test_a_driver_that_hangs_is_killed_and_is_a_failed_try(w, monkeypatch):
    monkeypatch.setattr(renew, "DRIVE_TIMEOUT_S", 1.0)
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "hang")
    t0 = time.time()
    w.run()
    assert time.time() - t0 < 30
    assert w.state()["accounts"][EMAIL["b85"]]["last"]["verdict"] == "driver_timeout"
    out = subprocess.run(["/bin/ps", "-axo", "command"], capture_output=True, text=True).stdout
    assert str(w.d / "claude") not in out


def test_a_driver_that_prints_no_verdict_is_a_failed_try_not_a_success(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "garbage")
    w.run()
    assert w.state()["accounts"][EMAIL["b85"]]["last"]["verdict"] == "driver_no_verdict"


# ── what cannot be automated: not circumvented, marked, ONE push ──────────────────
@pytest.mark.parametrize("verdict, must_say", [
    ("puzzle", ["human-verification puzzle", "not circumvent"]),
    ("no_google_session", ["Google account", "automation Chrome", "ONCE"]),
    ("needs_password", ["asked for the password", "automation Chrome", "ONCE"]),
    ("needs_device", ["phone", "security key"]),
])
def test_what_needs_a_human_is_marked_infeasible_and_athos_gets_one_push_with_the_exact_step(w, verdict, must_say):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.mp.setenv("FAKE_DRIVER_VERDICT", verdict)
    w.run()
    for i in range(1, 4):                                                        # three more runs, hours later: nothing is tried again, nothing is said again
        w.run(at=T0 + i * 7 * 3600)
    assert len(w.claude_calls()) == 1 and len(w.driver_calls()) == 1
    assert w.get(w.svc("b85")) == old
    mark = w.state()["accounts"][EMAIL["b85"]]["infeasible"]
    assert mark["verdict"] == verdict and mark["at"] == T0
    pushes = w.pushes()
    assert len(pushes) == 1
    assert EMAIL["b85"] in pushes[0] and "job falhou" in pushes[0] and "claude-login-renew" in pushes[0]
    for s in must_say:
        assert s in pushes[0], s
    cmd = f"mkdir -p {w.d / 'accts' / 'athosb85'} && CLAUDE_CONFIG_DIR={w.d / 'accts' / 'athosb85'} claude auth login --email {EMAIL['b85']}"
    assert (cmd in pushes[0]) == (verdict in ("puzzle", "needs_device"))         # the by-hand login line is the step when a HUMAN must pass something (nothing in it is a password)
    assert "password=" not in pushes[0].lower() and "senha" not in pushes[0].lower()


def test_an_undelivered_push_is_retried_not_forgotten(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")
    w.mp.setenv("FAKE_NOTIFY_RC", "7")
    w.run()
    assert len(w.pushes()) == 1 and not w.state()["accounts"][EMAIL["b85"]]["infeasible"].get("pushed")
    w.mp.setenv("FAKE_NOTIFY_RC", "0")
    w.run(at=T0 + 30)
    assert len(w.pushes()) == 1                                                  # not before the retry delay
    w.run(at=T0 + renew.PUSH_RETRY_S + 1)
    assert len(w.pushes()) == 2 and w.state()["accounts"][EMAIL["b85"]]["infeasible"]["pushed"] == T0 + renew.PUSH_RETRY_S + 1
    w.run(at=T0 + 10 * DAY)
    assert len(w.pushes()) == 2


@pytest.mark.parametrize("verdict", ["no_google_session", "needs_password"])
def test_a_wall_that_is_fixed_in_the_browser_is_looked_at_again_after_a_day_without_a_second_push(w, verdict):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", verdict)
    w.run()
    w.run(at=T0 + renew.RECHECK_S - 60)
    assert len(w.claude_calls()) == 1                                            # not before the day is out
    w.run(at=T0 + renew.RECHECK_S + 60)                                          # the Google account is still not in the Chrome: same wall, same mark
    assert len(w.claude_calls()) == 2 and len(w.pushes()) == 1
    mark = w.state()["accounts"][EMAIL["b85"]]["infeasible"]
    assert mark["verdict"] == verdict and mark["pushed"] == T0 and mark["recheck_at"] == T0 + renew.RECHECK_S + 60 + renew.RECHECK_S
    w.mp.setenv("FAKE_DRIVER_VERDICT", "ok")                                     # Athos signed the account in: the next look renews it, the mark goes
    w.login_will_be("b85", blob("b85-auto"))
    w.run(at=T0 + 2 * renew.RECHECK_S + 120)
    a = w.state()["accounts"][EMAIL["b85"]]
    assert "infeasible" not in a and a["renewed"]["after"]["rfp"] == fps(blob("b85-auto"))[1] and len(w.pushes()) == 1


def test_a_wall_that_only_a_hand_login_fixes_is_never_looked_at_again_by_the_clock(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")
    w.run()
    for d in (2, 5, 30):
        w.run(at=T0 + d * DAY)
    assert len(w.claude_calls()) == 1 and "recheck_at" not in w.state()["accounts"][EMAIL["b85"]]["infeasible"]


def test_a_different_wall_after_a_mark_is_a_new_step_for_athos_and_gets_its_own_push(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "no_google_session")
    w.run()
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")                                 # he signed in, and the next wall is the puzzle
    w.run(at=T0 + renew.RECHECK_S + 60)
    pushes = w.pushes()
    assert len(pushes) == 2 and "Google account" in pushes[0] and "human-verification" in pushes[1]


@pytest.mark.parametrize("rc, delivered", [(0, True), (10, True), (11, True), (12, False), (7, False)])
def test_a_push_counts_as_delivered_only_on_the_strict_exit_codes(w, rc, delivered):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")
    w.mp.setenv("FAKE_NOTIFY_RC", str(rc))
    w.run()
    assert bool(w.state()["accounts"][EMAIL["b85"]]["infeasible"].get("pushed")) is delivered
    assert (w.d / "notify.env").read_text().split() == ["1/1"]                    # NOTIFY_STRICT_EXIT=1 and NOTIFY_FORCE_PUSH=1


def test_a_transient_failure_backs_off_and_the_third_one_becomes_infeasible_with_one_push(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "fail")
    w.run()
    a = w.state()["accounts"][EMAIL["b85"]]
    assert a["tries"] == 1 and a["next_at"] == T0 + renew.RETRY_S
    w.run(at=T0 + renew.RETRY_S - 1)
    assert len(w.claude_calls()) == 1                                            # not before the back-off
    w.run(at=T0 + renew.RETRY_S)
    assert len(w.claude_calls()) == 2 and w.pushes() == []
    w.run(at=T0 + 2 * renew.RETRY_S)
    assert len(w.claude_calls()) == 3
    mark = w.state()["accounts"][EMAIL["b85"]]["infeasible"]
    assert mark["verdict"] == "failed_3_times" and len(w.pushes()) == 1
    w.run(at=T0 + 9 * renew.RETRY_S)
    assert len(w.claude_calls()) == 3 and len(w.pushes()) == 1


def test_a_login_made_by_hand_takes_the_account_back_into_rotation(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")
    w.run()
    assert "infeasible" in w.state()["accounts"][EMAIL["b85"]]
    w.own("b85", blob("b85-by-hand", rexp_days=3.5))                             # a refresh adds hours, not a day: still marked
    w.run(at=T0 + 3600)
    assert "infeasible" in w.state()["accounts"][EMAIL["b85"]]
    w.own("b85", blob("b85-by-hand", rexp_days=20.0))                            # a whole new login: back in rotation, and not due, so nothing is launched
    w.run(at=T0 + 7200)
    assert "infeasible" not in w.state()["accounts"][EMAIL["b85"]] and len(w.claude_calls()) == 1
    w.mp.setenv("FAKE_DRIVER_VERDICT", "ok")
    w.login_will_be("b85", blob("b85-auto"))
    w.run(at=T0 + 14.5 * DAY)                                                    # 5.5 days left on the hand login: due again, and this time it works
    assert fps(w.get(w.svc("b85"))) == fps(blob("b85-auto"))


def test_a_success_clears_the_tries(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "fail")
    w.run()
    w.mp.setenv("FAKE_CLAUDE_MODE", "")
    w.login_will_be("b85", blob("b85-new"))
    w.run(at=T0 + renew.RETRY_S)
    a = w.state()["accounts"][EMAIL["b85"]]
    assert a["renewed"]["at"] == T0 + renew.RETRY_S and "tries" not in a and "next_at" not in a


# ── controls ────────────────────────────────────────────────────────────────────
def test_the_kill_switch_file_and_the_env_stop_everything(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    (w.d / "city" / ".gc" / "no-login-renew").write_text("")
    w.run()
    assert w.claude_calls() == []
    (w.d / "city" / ".gc" / "no-login-renew").unlink()
    w.mp.setenv("GC_LOGIN_RENEW", "0")
    w.run()
    assert w.claude_calls() == [] and not (w.d / "renew_state.json").exists()


def test_a_dry_run_launches_nothing_writes_nothing_says_nothing(w):
    w.own("b85", blob("b85", rexp_days=3.0))
    before = w.store()
    w.run(dry=True)
    assert w.claude_calls() == [] and w.store() == before and w.pushes() == [] and not (w.d / "renew_state.json").exists()
    assert w.log() == ""                                                          # a dry run does not write the real log


def test_force_names_an_account_and_ignores_the_forecast_and_the_marks(w):
    w.own("b85", blob("b85", rexp_days=25.0))
    w.login_will_be("b85", blob("b85-forced", rexp_days=30.0))
    w.run(only=EMAIL["b85"], force=True)
    assert fps(w.get(w.svc("b85"))) == fps(blob("b85-forced"))
    assert w.state()["accounts"][EMAIL["b85"]]["renewed"]["reason"] == "forced"


def test_force_on_an_unknown_account_or_one_without_a_dir_does_nothing(w):
    assert w.run(only="nobody@example.com", force=True) == 0
    assert w.run(only=EMAIL["martins"], force=True) == 0
    assert w.claude_calls() == []
    assert "no config dir" in w.log() or "not one of" in w.log()


def test_a_second_instance_does_nothing(w):
    import fcntl
    w.own("b85", blob("b85", rexp_days=3.0))
    lock = w.d / "city" / ".gc" / "claude-login-renew.lock"
    fd = os.open(str(lock), os.O_CREAT | os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        assert renew.main([]) == 0
    finally:
        os.close(fd)
    assert w.claude_calls() == []


# ── the screens the driver reads (pure) ─────────────────────────────────────────
E = EMAIL["b85"]


def scr(url, text="", ids=(), pw=False, code=False, buttons=(), email_box=False):
    return renew.classify(E, url, text, list(ids), pw, code, list(buttons), email_box)


@pytest.mark.parametrize("args, want", [
    (("https://claude.ai/login", "Your thinking partner", (), False, False, ["continue with google", "continue with email"]), "click_google"),
    (("https://accounts.google.com/v3/signin/accountchooser", "Choose an account", [E, "x@gmail.com"], False, False, []), "pick"),
    (("https://accounts.google.com/v3/signin/accountchooser", "Choose an account", ["x@gmail.com"], False, False, []), "no_google_session"),
    (("https://accounts.google.com/v3/signin/challenge/pwd", "Welcome", (), True, False, ["next"]), "needs_password"),
    (("https://accounts.google.com/v3/signin/challenge/totp", "2-Step Verification Enter the code", (), False, True, ["next"]), "enter_code"),
    (("https://accounts.google.com/v3/signin/challenge/ipp", "Check your phone Tap Yes on your phone", (), False, False, ["try another way"]), "needs_device"),
    (("https://accounts.google.com/v3/signin/challenge/sk", "Use your security key", (), False, False, []), "needs_device"),
    (("https://accounts.google.com/signin/oauth/consent", "Sign in to Claude", (), False, False, ["cancel", "continue"]), "click_continue"),
    (("https://claude.ai/oauth/authorize", f"Claude Code would like to connect {E}", (), False, False, ["authorize", "deny"]), "click_authorize"),
    (("https://claude.ai/oauth/authorize", "Claude Code would like to connect", (), False, False, ["authorize"]), "click_authorize"),
    (("https://claude.ai/oauth/authorize", "Claude Code would like to connect other@gmail.com", (), False, False, ["authorize"]), "wrong_account"),
    (("https://claude.ai/oauth/authorize", f"would like to connect {E} and other@gmail.com", (), False, False, ["authorize"]), "click_authorize"),
    (("https://claude.ai/oauth/authorize", "Drag the animal into the correct silhouette", (), False, False, ["authorize"]), "puzzle"),
    (("https://claude.ai/login", "Verify you're human", (), False, False, ["continue with google"]), "puzzle"),
    (("https://accounts.google.com/x", "Please solve the CAPTCHA to continue", (), False, False, []), "puzzle"),
    (("https://claude.ai/login", "This site is protected by reCAPTCHA", (), False, False, ["continue with google"]), "click_google"),
    (("http://localhost:5555/callback", "", (), False, False, []), "done"),
    (("http://127.0.0.1:5555/callback", "", (), False, False, []), "done"),
    (("https://claude.ai/loading", "", (), False, False, []), "wait"),
    (("about:blank", "", (), False, False, []), "wait"),
])
def test_every_screen_the_driver_can_meet_has_one_answer(args, want):
    assert scr(*args) == want


def test_google_asking_which_email_to_sign_in_is_a_profile_with_no_google_session_and_nothing_is_typed_into_it():
    assert scr("https://accounts.google.com/v3/signin/identifier", "Sign in", email_box=True) == "no_google_session"
    assert scr("https://accounts.google.com/v3/signin/identifier", "Sign in", buttons=["next"], email_box=True) == "no_google_session"
    assert scr("https://accounts.google.com/a", "", ids=[E], email_box=True) == "pick"                      # a chooser that also offers "use another account" still picks
    assert scr("https://accounts.google.com/a", "", pw=True, email_box=True) == "needs_password"            # a password box outranks it


def test_the_email_on_the_chooser_is_matched_case_blind_and_exactly():
    assert renew.classify(E.upper(), "https://accounts.google.com/a", "", [E], False, False, []) == "pick"
    assert renew.classify(E, "https://accounts.google.com/a", "", ["x" + E], False, False, []) == "no_google_session"


@pytest.mark.parametrize("url, ok", [
    ("https://claude.ai/oauth/authorize?x=1", True), ("https://claude.com/cai/oauth/authorize?x=1", True),
    ("https://platform.claude.com/oauth/authorize?x=1", True), ("https://console.anthropic.com/oauth/authorize", True),
    ("http://claude.ai/oauth/authorize", False), ("https://claude.ai.evil.com/oauth/authorize", False),
    ("https://evil.com/?u=https://claude.ai/", False), ("file:///etc/passwd", False), ("javascript:alert(1)", False), ("", False),
    ("https://claude.ai/oauth/authorize\nhttps://evil.com", False),
])
def test_the_driver_only_ever_navigates_to_anthropic(url, ok):
    assert renew.valid_oauth_url(url) is ok


# ── the script as launchd runs it ──────────────────────────────────────────────
@pytest.mark.parametrize("py", ["/usr/bin/python3", sys.executable])
def test_the_real_script_runs_from_an_empty_environment_under_both_interpreters(w, py):
    w.own("b85", blob("b85", rexp_days=3.0))
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "CLAUDE_CREW_NOW": str(T0), "CLAUDE_CREW_USER": "athos",
           "FAKE_SEC_DIR": str(w.d), "CLAUDE_CREW_SECURITY": str(w.d / "security"), "CLAUDE_CREW_NOTIFY": str(w.d / "notify"),
           "CLAUDE_CREW_STATE": str(w.d / "crew_state.json"), "CLAUDE_RENEW_STATE": str(w.d / "renew_state.json"),
           "CLAUDE_CREW_DECISION": str(w.d / "pool_decision.json"), "CLAUDE_CREW_ACCOUNTS_DIR": str(w.d / "accts"),
           "GC_CITY_PATH": str(w.d / "city"), "CLAUDE_RENEW_CLAUDE": str(w.d / "claude"), "CLAUDE_RENEW_DRIVER": os.environ["CLAUDE_RENEW_DRIVER"],
           "FAKE_DRIVER_VERDICT": "puzzle", "CLAUDE_CREW_PROFILE_URL": os.environ["CLAUDE_CREW_PROFILE_URL"]}
    r = subprocess.run([py, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert w.state()["accounts"][EMAIL["b85"]]["infeasible"]["verdict"] == "puzzle"
    assert len(w.pushes()) == 1


def test_the_plist_is_well_formed_xml_not_just_text_that_looks_right():
    import plistlib
    raw = (HERE.parents[1] / "packs" / "town-deltas" / "assets" / "claude-login-renew.plist").read_bytes()
    try:
        d = plistlib.loads(raw)                                                  # strict XML: a double hyphen inside a comment is accepted by launchd and refused here (and by the pre-push plist lint)
    except Exception as e:  # noqa: BLE001
        pytest.fail(f"the plist does not parse as XML: {type(e).__name__}: {e}")
    assert d["Label"] == "com.gascity.claude-login-renew" and d["StartInterval"] == 900 and d["RunAtLoad"] is False
    assert d["ProgramArguments"][0] == "/usr/bin/python3" and d["ProgramArguments"][1].endswith("/scripts/claude-login-renew.py")
    assert set(d["EnvironmentVariables"]) >= {"PATH", "HOME", "USER", "GC_CITY_PATH"}


def test_the_plist_names_the_job_and_does_not_collide_with_the_quota_swap_job():
    p = (HERE.parents[1] / "packs" / "town-deltas" / "assets" / "claude-login-renew.plist").read_text()
    assert "<key>Label</key><string>com.gascity.claude-login-renew</string>" in p
    assert "<string>com.gascity.claude-account-relog</string>" not in p                  # ga-jf689's quota-swap job owns that label
    assert "claude-login-renew.py" in p and "/Users/athos/.local/bin" in p and "<key>RunAtLoad</key><false/>" in p
    assert int(re.search(r"<key>StartInterval</key><integer>(\d+)</integer>", p).group(1)) >= 300
