"""ga-xoe5ao.5.1/.5.2/.5.3 — claude-login-renew.py: `--account <e> --force` renews ONE Claude account's login through gmail-totp + the Chrome CDP,
what the automation does not get around becomes a mark in the state plus ONE push (the "what cannot be automated" block), and the scheduled run
(no arguments) launches AT MOST ONE attempt, on the forecast (a login ends in <= 7 days) or the outage (no full login anywhere) — the "scheduled run" blocks.

No network, no real browser, no real Keychain: `security` is a json store, `claude` is a fake that asks "the browser" (`open <url>`) and only finishes
when the fake driver says the callback happened, the driver is a fake that prints a verdict, the profile is a loopback server. What this proves:
  * the attempt: `claude auth login --email <e>` in the account's OWN config dir, the OAuth URL captured by a PATH shim (Athos's browser never opens) and
    handed to the driver on STDIN (never argv, log or stdout), the new login judged by what is in the Keychain item and by whose it is, else put back;
  * anti-bot puzzle / Google asking for what this job does not do / a browser signed in as another account: NOT circumvented, no retry, said;
  * the third state: an item that cannot be read is never overwritten; a driver or CLI that hangs, lies or cannot be read is a failed try, not a success.
"""
import http.server
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve()
SCRIPT = HERE.parents[1] / "packs" / "town-deltas" / "assets" / "scripts" / "claude-login-renew.py"
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
        store[m.group(2)] = {"acct": m.group(1), "secret": bytes.fromhex(m.group(3)).decode()}
    json.dump(store, open(store_p, "w"))
    sys.exit(0)
svc = a[a.index("-s") + 1] if "-s" in a else ""
if a and a[0] == "delete-generic-password":
    if svc not in store:
        sys.exit(44)
    del store[svc]
    json.dump(store, open(store_p, "w"))
    open(os.path.join(d, "deletes.log"), "a").write(svc + "\n")
    sys.exit(0)
if a and a[0] == "find-generic-password":
    if svc in os.environ.get("FAKE_SEC_FAIL", "").split("|"):
        sys.exit(1)
    if svc not in store:
        sys.exit(44)
    print(store[svc]["secret"] if "-w" in a else 'keychain: "login.keychain-db"\n    "acct"<blob>="%s"\n    "svce"<blob>="%s"' % (store[svc]["acct"], svc))
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
URL = "https://claude.ai/oauth/authorize?client_id=x&state=SECRETSTATE-0123456789&code_challenge=CHALLENGE-abcdef&redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcallback"
if mode != "noopen":
    subprocess.run(["open", URL], check=False)
    print("If the browser did not open, visit: " + URL)       # what the real CLI prints: nobody may copy it into a log
else:
    sys.exit(0)
cb = os.path.join(d, "callback")
end = time.time() + 20
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
'''

FAKE_NOTIFY = r'''#!/usr/bin/env python3
import json, os, sys
open(os.path.join(os.environ["FAKE_SEC_DIR"], "notify.log"), "a").write(json.dumps({"argv": sys.argv[1:], "strict": os.environ.get("NOTIFY_STRICT_EXIT")}) + "\n")
sys.exit(int(os.environ.get("FAKE_NOTIFY_RC", "0")))
'''

FAKE_DRIVER = r'''#!/usr/bin/env python3
import json, os, sys, time
d = os.environ["FAKE_SEC_DIR"]
url = sys.stdin.read()
with open(os.path.join(d, "driver.log"), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "stdin_has_url": url.startswith("https://claude.ai/")}) + "\n")
v = os.environ.get("FAKE_DRIVER_VERDICT", "ok")
if v == "hang":
    time.sleep(120)
print("some playwright chatter that is not json")
if v == "garbage":
    sys.exit(0)
if v == "ok":
    open(os.path.join(d, "callback"), "w").write("x")
print(json.dumps({"verdict": v, "step": "at claude.ai/oauth/authorize"}))
'''

EMAIL = {"crypto": "athoscrypto@gmail.com", "b85": "athosb85@gmail.com", "martins": "athosmartins@gmail.com", "terr": "terrenos.incorporacoes@gmail.com",
         "amb": "throw.away.amb@gmail.com"}
T0 = float(int(time.time()))
DAY = 86400
_GUARD: dict = {}


def blob(tag, *, rexp_days=29.0, scopes=None):
    o = {"accessToken": f"sk-ant-oat01-{tag}-acc", "expiresAt": int((T0 + 7 * 3600) * 1000), "refreshToken": f"sk-ant-ort01-{tag}-ref",
         "refreshTokenExpiresAt": int((T0 + rexp_days * DAY) * 1000), "subscriptionType": "max",
         "scopes": scopes if scopes is not None else ["user:inference", "user:profile", "user:sessions:claude_code"]}
    return {"claudeAiOauth": o}


def fps(b):
    return crew.fp(b["claudeAiOauth"]["accessToken"]), crew.fp(b["claudeAiOauth"]["refreshToken"])


@pytest.fixture(scope="session", autouse=True)
def _nothing_real_was_touched(tmp_path_factory):
    guard = tmp_path_factory.mktemp("guard")
    hits = guard / "hits.log"
    for n in ("security", "claude", "open", "xdg-open", "gmail-totp", "notify"):
        (guard / n).write_text(f'#!/bin/sh\necho "$0 $*" >> "{hits}"\nexit 99\n')
        (guard / n).chmod(0o700)
    _GUARD.update(dir=guard, hits=hits)
    yield
    assert not hits.exists(), "a test reached a REAL security/claude/open/gmail-totp (sentinel executed):\n" + hits.read_text()


@pytest.fixture(autouse=True)
def _pin_env(monkeypatch, tmp_path):
    g = _GUARD["dir"]
    for k, v in {"CLAUDE_CREW_SECURITY": g / "security", "CLAUDE_RENEW_CLAUDE": g / "claude", "CLAUDE_RENEW_DRIVER": json.dumps([str(g / "gmail-totp")]),
                 "GC_CITY_PATH": tmp_path / "pinned-city", "CLAUDE_CREW_STATE": tmp_path / "pinned-crew-state.json",
                 "CLAUDE_CREW_ACCOUNTS_DIR": tmp_path / "pinned-accts", "HOME": tmp_path / "pinned-home", "CLAUDE_CREW_NOTIFY": g / "notify",
                 "CLAUDE_RENEW_STATE": tmp_path / "pinned-renew-state.json", "CLAUDE_CREW_DECISION": tmp_path / "pinned-decision.json"}.items():
        monkeypatch.setenv(k, str(v))
    monkeypatch.setenv("PATH", f"{g}:/usr/bin:/bin")


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
        for name, body in (("security", FAKE_SECURITY), ("claude", FAKE_CLAUDE), ("driver", FAKE_DRIVER), ("notify", FAKE_NOTIFY)):
            (self.d / name).write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))
            (self.d / name).chmod(0o700)
        (self.d / "city" / ".gc" / "logs").mkdir(parents=True)
        for k, v in {"FAKE_SEC_DIR": str(self.d), "CLAUDE_CREW_SECURITY": str(self.d / "security"), "CLAUDE_RENEW_CLAUDE": str(self.d / "claude"),
                     "CLAUDE_RENEW_DRIVER": json.dumps([str(self.d / "driver"), "drive"]), "CLAUDE_CREW_STATE": str(self.d / "crew_state.json"),
                     "CLAUDE_CREW_NOTIFY": str(self.d / "notify"), "CLAUDE_RENEW_STATE": str(self.d / "renew_state.json"), "CLAUDE_CREW_DECISION": str(self.d / "pool_decision.json"),
                     "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
                     "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(T0)}.items():
            monkeypatch.setenv(k, v)
        for k in ("CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL", "FAKE_CLAUDE_MODE", "FAKE_DRIVER_VERDICT", "FAKE_CLAUDE_BLOB", "FAKE_NOTIFY_RC", "GC_LOGIN_RENEW"):
            monkeypatch.delenv(k, raising=False)
        monkeypatch.setattr(renew, "DRY", False, raising=False)  # main() sets it for the whole process: no test leaves a dry run behind
        self.mp = monkeypatch
        self.crew_state()                                          # the crew job's state: empty but READABLE (a missing or corrupt one is a case of its own)
        assert str(crew.security_bin()).startswith(str(self.d)) and str(crew.city()).startswith(str(self.d))

    def store(self):
        p = self.d / "store.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def put(self, service, b):
        s = self.store()
        s[service] = {"acct": "athos", "secret": json.dumps(b)}
        (self.d / "store.json").write_text(json.dumps(s))

    def own(self, key, b):
        self.put(self.svc(key), b)

    def default(self, key, b):
        self.put(crew.DEFAULT_SERVICE, b)
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[key]

    def crew_state(self, **kw):
        (self.d / "crew_state.json").write_text(json.dumps(kw))

    def decide(self, key):
        (self.d / "pool_decision.json").write_text(json.dumps({"current": EMAIL[key], "updated": crew._iso(T0), "schema": 1, "exhausted": {}}))

    def get(self, service):
        v = self.store().get(service)
        return json.loads(v["secret"]) if v else None

    def svc(self, key):
        return crew.dir_service(str(self.d / "accts" / {"crypto": "athoscrypto", "b85": "athosb85", "terr": "terrenos", "amb": "throw.away.amb"}[key]))

    def login_will_be(self, key, b, *, owner=None):
        """What the fake CLI stores when the browser dance works: `b`, whose access token the profile says belongs to `owner` (default: `key`)."""
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[owner or key]
        self.mp.setenv("FAKE_CLAUDE_BLOB", json.dumps(b))

    def run(self, key="b85"):
        return renew.run_once(EMAIL[key])

    def state(self):
        p = self.d / "renew_state.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def mark(self, key="b85"):
        return (self.state().get("accounts", {}).get(EMAIL[key]) or {}).get("infeasible")

    def at(self, secs):
        self.mp.setenv("CLAUDE_CREW_NOW", str(T0 + secs))

    def log(self):
        p = self.d / "city" / ".gc" / "logs" / "claude-login-renew.log"
        return p.read_text() if p.exists() else ""

    def calls(self, name):
        p = self.d / f"{name}.log"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


@pytest.fixture
def w(tmp_path, monkeypatch):
    return World(tmp_path, monkeypatch)


# ── the attempt ─────────────────────────────────────────────────────────────────
def test_a_forced_relogin_runs_in_the_accounts_own_dir_and_the_proof_is_fingerprints_and_dates(w, capsys):
    old, new = blob("b85-old", rexp_days=3.0), blob("b85-new", rexp_days=30.0)
    w.own("b85", old)
    w.login_will_be("b85", new)
    assert w.run() == 0
    out = capsys.readouterr().out
    assert fps(w.get(w.svc("b85"))) == fps(new)
    assert [c["cfg"] for c in w.calls("claude")] == [str(w.d / "accts" / "athosb85")]
    assert w.calls("claude")[0]["argv"] == ["auth", "login", "--email", EMAIL["b85"]]
    for line in (out, w.log()):
        assert f"{fps(old)[1]} -> {fps(new)[1]}" in line and "renewed" in line and crew._iso(T0 + 30 * DAY) in line
    assert "sk-ant" not in out + w.log()


def test_the_oauth_url_goes_to_the_driver_on_stdin_and_no_secret_rides_anywhere_else(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-new"))
    w.run()
    assert w.calls("driver") == [{"argv": ["drive"], "stdin_has_url": True}]
    everything = capsys.readouterr().out + w.log() + (w.d / "argv.log").read_text() + json.dumps(w.calls("claude"))
    for needle in ("SECRETSTATE", "CHALLENGE-abcdef", "oauth/authorize?", "sk-ant-", "refreshToken"):
        assert needle not in everything, needle
    assert w.calls("claude")[0]["path0"] != str(_GUARD["dir"])                      # the PATH shim (`open`) was first: Athos's browser never opened
    assert not _GUARD["hits"].exists()


def test_the_shim_directory_does_not_outlive_the_attempt(w, tmp_path, monkeypatch):
    import tempfile
    (tmp_path / "tmpdir").mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "tmpdir"))
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-new"))
    w.run()
    assert list((tmp_path / "tmpdir").iterdir()) == []


def test_a_login_that_is_not_a_full_login_is_not_renewed_and_the_old_item_comes_back_as_it_was(w, capsys):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.login_will_be("b85", blob("b85-nosession", scopes=["user:inference"]))
    assert w.run() == 2
    assert w.get(w.svc("b85")) == old and "no_full_login" in capsys.readouterr().out


def test_a_login_that_belongs_to_another_account_is_put_back(w, capsys):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.login_will_be("b85", blob("crypto-by-mistake"), owner="crypto")
    assert w.run() == 2
    assert w.get(w.svc("b85")) == old and "wrong_account" in capsys.readouterr().out


def test_a_first_login_that_landed_on_the_wrong_account_is_removed_not_kept(w):
    w.login_will_be("b85", blob("crypto-by-mistake"), owner="crypto")
    assert w.run() == 2
    assert w.get(w.svc("b85")) is None and (w.d / "deletes.log").read_text().splitlines() == [w.svc("b85")]


@pytest.mark.parametrize("verdict", ["puzzle", "no_google_session", "needs_password", "needs_device", "wrong_account"])
def test_a_wall_is_not_circumvented_not_retried_and_said_with_the_hand_step(w, capsys, verdict):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.mp.setenv("FAKE_DRIVER_VERDICT", verdict)
    assert w.run() == 2
    out = capsys.readouterr().out
    assert verdict in out and "marked 'inviavel por automacao'" in out and crew.relogin_cmd(EMAIL["b85"]) in out
    assert len(w.calls("driver")) == 1 and len(w.calls("claude")) == 1 and w.get(w.svc("b85")) == old
    assert w.mark()["verdict"] == verdict and len(w.calls("notify")) == 1                  # the mark and its ONE push, end to end through the real attempt


def test_a_full_login_made_by_hand_while_the_job_stood_at_a_wall_is_kept_not_put_back(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.login_will_be("b85", blob("b85-by-hand", rexp_days=30.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "puzzle")                                    # the driver stops at the puzzle and never writes the callback ...
    (w.d / "callback").write_text("x")                                              # ... but the CLI finishes anyway: somebody logged in by hand in that dir
    assert w.run() == 0 and fps(w.get(w.svc("b85"))) == fps(blob("b85-by-hand")) and "renewed" in capsys.readouterr().out


def test_a_cli_that_exits_without_ever_asking_for_a_browser_is_a_failed_try(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "noopen")
    assert w.run() == 2
    assert w.calls("driver") == [] and "no_browser_request" in capsys.readouterr().out


def test_a_cli_that_fails_after_the_driver_said_ok_is_a_failed_try(w, capsys):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.mp.setenv("FAKE_CLAUDE_MODE", "late_fail")
    assert w.run() == 2
    assert len(w.calls("driver")) == 1 and w.get(w.svc("b85")) == old and "no_full_login" in capsys.readouterr().out


def test_a_cli_that_never_finishes_is_killed_and_is_a_failed_try(w, monkeypatch):
    monkeypatch.setattr(renew, "CLI_WAIT_S", 1.0)
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_CLAUDE_MODE", "hang")
    t0 = time.time()
    assert w.run() == 2 and time.time() - t0 < 30
    assert str(w.d / "claude") not in subprocess.run(["/bin/ps", "-axo", "command"], capture_output=True, text=True).stdout


def test_a_driver_that_hangs_is_killed_and_is_a_failed_try(w, monkeypatch, capsys):
    monkeypatch.setattr(renew, "DRIVE_TIMEOUT_S", 1.0)
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "hang")
    t0 = time.time()
    assert w.run() == 2 and time.time() - t0 < 30 and "driver_timeout" in capsys.readouterr().out
    assert str(w.d / "claude") not in subprocess.run(["/bin/ps", "-axo", "command"], capture_output=True, text=True).stdout


def test_a_driver_that_prints_no_verdict_is_a_failed_try_not_a_success(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_DRIVER_VERDICT", "garbage")
    assert w.run() == 2 and "driver_no_verdict" in capsys.readouterr().out


def test_a_driver_command_that_is_not_a_json_list_is_said_and_the_default_driver_is_used(w):
    w.mp.setenv("CLAUDE_RENEW_DRIVER", "{not json")
    assert renew.driver_cmd()[-1] == "drive" and "not a json list" in w.log()


# ── reads that fail: the third state is said out loud, never a silent verdict ───────────────────
def test_an_item_that_cannot_be_read_is_not_attempted_and_never_overwritten(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_SEC_FAIL", w.svc("b85"))
    assert w.run() == 2
    assert w.calls("claude") == [] and w.calls("driver") == [] and "could not be read" in capsys.readouterr().out


def test_an_item_that_cannot_be_read_after_the_try_is_said_as_unreadable_not_as_no_new_login_and_left_alone(w, monkeypatch, capsys):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    real = crew.kc_read

    def flaky(svc):                                                              # the reads before the try (survey, snapshot) work, the one after it does not
        return real(svc) if not w.calls("claude") else ("unknown", None, None)
    monkeypatch.setattr(crew, "kc_read", flaky)
    assert w.run() == 2
    out = capsys.readouterr().out
    assert "keychain_unreadable" in out and "no_full_login" not in out and w.get(w.svc("b85")) == old
    assert (w.d / "deletes.log").exists() is False


def test_a_put_back_that_fails_is_said_on_the_printed_line_not_only_in_the_log(w, monkeypatch, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.login_will_be("b85", blob("crypto-by-mistake"), owner="crypto")
    monkeypatch.setattr(renew, "put_back", lambda *a: False)
    assert w.run() == 2
    assert "wrong_account" in (out := capsys.readouterr().out) and "could NOT be put back" in out and "could NOT be put back" in w.log()


def test_a_login_kept_with_the_owner_unverified_says_so_on_the_printed_line(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    new = blob("b85-new", rexp_days=30.0)
    w.login_will_be("b85", new)
    w.tokens.clear()                                                             # the profile answers 401 for every token: it cannot say whose the login is
    assert w.run() == 0
    assert "owner unverified" in capsys.readouterr().out and fps(w.get(w.svc("b85"))) == fps(new)


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


def test_a_url_file_that_cannot_be_read_and_a_dead_cli_is_no_url_not_a_crash(tmp_path):
    class Dead:
        def poll(self):
            return 1
    (tmp_path / "url").mkdir()                                                   # read_text() -> IsADirectoryError (an OSError)
    assert renew.wait_for_url(Dead(), tmp_path / "url") is None
    assert renew.wait_for_url(Dead(), tmp_path / "never-written") is None


# ── what is asked of the CLI ────────────────────────────────────────────────────
def test_an_account_that_is_unknown_or_has_no_config_dir_is_never_attempted(w, capsys):
    assert w.run("martins") == 2 and renew.run_once("nobody@example.com") == 2
    assert w.calls("claude") == [] and capsys.readouterr().err.count("not one of the accounts with a config dir") == 2


@pytest.mark.parametrize("argv", [["--account", EMAIL["b85"]], ["--force"], ["--force", "--account"]])
def test_without_both_an_account_and_force_nothing_is_launched(w, capsys, argv):
    assert renew.main(argv) == 64 and w.calls("claude") == [] and "usage" in capsys.readouterr().err


@pytest.mark.parametrize("py", ["/usr/bin/python3", sys.executable])
def test_the_real_script_runs_from_an_empty_environment_under_both_interpreters(w, py):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "CLAUDE_CREW_NOW": str(T0), "CLAUDE_CREW_USER": "athos", "FAKE_SEC_DIR": str(w.d),
           "CLAUDE_CREW_SECURITY": str(w.d / "security"), "CLAUDE_CREW_STATE": str(w.d / "crew_state.json"), "CLAUDE_CREW_ACCOUNTS_DIR": str(w.d / "accts"),
           "GC_CITY_PATH": str(w.d / "city"), "CLAUDE_RENEW_CLAUDE": str(w.d / "claude"), "CLAUDE_RENEW_DRIVER": os.environ["CLAUDE_RENEW_DRIVER"],
           "FAKE_DRIVER_VERDICT": "puzzle", "CLAUDE_CREW_PROFILE_URL": os.environ["CLAUDE_CREW_PROFILE_URL"],
           # everything the script WRITES or CALLS is pinned into the world: without these the child falls back to the REAL
           # shared state file (a fake mark on the real athosb85) and to whatever `notify` the PATH finds (ga-xoe5ao.5.3)
           "CLAUDE_RENEW_STATE": str(w.d / "renew_state.json"), "CLAUDE_CREW_DECISION": str(w.d / "pool_decision.json"), "CLAUDE_CREW_NOTIFY": str(w.d / "notify")}
    r = subprocess.run([py, str(SCRIPT), "--account", EMAIL["b85"], "--force"], env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 2 and "puzzle" in r.stdout, r.stderr
    mark = json.loads((w.d / "renew_state.json").read_text())["accounts"][EMAIL["b85"]]["infeasible"]    # the mark landed in THIS world's state, not the real one
    assert mark["verdict"] == "puzzle" and mark["left"] == pytest.approx(3 * 86400, abs=5)


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
    (("https://accounts.google.com/signin/oauth/consent", "Sign in to Claude", (), False, False, ["cancel", "continue"]), "click_continue"),
    (("https://claude.ai/oauth/authorize", f"Claude Code would like to connect {E}", (), False, False, ["authorize", "deny"]), "click_authorize"),
    (("https://claude.ai/oauth/authorize", "Claude Code would like to connect other@gmail.com", (), False, False, ["authorize"]), "wrong_account"),
    (("https://claude.ai/oauth/authorize", "Drag the animal into the correct silhouette", (), False, False, ["authorize"]), "puzzle"),
    (("https://claude.ai/login", "Verify you're human", (), False, False, ["continue with google"]), "puzzle"),
    (("https://claude.ai/login", "This site is protected by reCAPTCHA", (), False, False, ["continue with google"]), "click_google"),
    (("http://localhost:5555/callback", "", (), False, False, []), "done"),
    (("https://claude.ai/loading", "", (), False, False, []), "wait"),
    (("https://platform.claude.com/oauth/authorize", f"connect {E}", (), False, False, ["authorize"]), "click_authorize"),
    (("https://evilclaude.com/oauth/authorize", f"connect {E}", (), False, False, ["authorize"]), "wait"),             # a host that merely ENDS in the letters is not Anthropic's
    (("https://claude.ai.evil.com/login", "", (), False, False, ["continue with google"]), "wait"),
    (("https://notclaude.ai/login", "", (), False, False, ["continue with google"]), "wait"),
])
def test_every_screen_the_driver_can_meet_has_one_answer(args, want):
    assert scr(*args) == want


def test_google_asking_which_email_to_sign_in_is_a_profile_with_no_google_session_and_nothing_is_typed_into_it():
    assert scr("https://accounts.google.com/v3/signin/identifier", "Sign in", email_box=True) == "no_google_session"
    assert scr("https://accounts.google.com/a", "", ids=[E], email_box=True) == "pick"                      # a chooser that also offers "use another account" still picks
    assert scr("https://accounts.google.com/a", "", pw=True, email_box=True) == "needs_password"            # a password box outranks it


def test_the_email_on_the_chooser_is_matched_case_blind_and_exactly():
    assert renew.classify(E.upper(), "https://accounts.google.com/a", "", [E], False, False, []) == "pick"
    assert renew.classify(E, "https://accounts.google.com/a", "", ["x" + E], False, False, []) == "no_google_session"


class _Loc:
    def __init__(self, boom):
        self.boom = boom

    def count(self):
        if self.boom:
            raise RuntimeError("navigating")
        return 0

    def all(self):
        return []

    def all_inner_texts(self):
        return []


class _Page:
    url = "https://claude.ai/oauth/authorize"

    def __init__(self, text_boom):
        self.text_boom = text_boom

    def inner_text(self, sel, timeout=0):
        if self.text_boom:
            raise RuntimeError("timeout")
        return "" if self.text_boom is None else "Authorize"

    def locator(self, sel):
        return _Loc(False)


def test_a_page_whose_text_cannot_be_read_is_not_a_page_with_nothing_on_it():
    assert renew.look(_Page(True))["text"] is None                                # unreadable: the driver skips it, so no puzzle check is bypassed and nothing is clicked
    assert renew.look(_Page(None))["text"] == ""                                  # readable and empty: an empty page, which classify answers on its own


class _FPage:
    def __init__(self, url, text="", buttons=()):
        self.url, self.text, self.buttons, self.closed, self.clicks, self.handlers = url, text, list(buttons), False, [], []

    def on(self, ev, fn):
        self.handlers.append(ev)

    def goto(self, *a, **k):
        pass

    def inner_text(self, sel, timeout=0):
        return self.text

    def locator(self, sel):
        return _Loc(False)

    def get_by_role(self, *a, **k):
        raise AssertionError("a click was attempted on " + self.url)

    def is_closed(self):
        return self.closed

    def close(self):
        self.closed = True


def test_the_driver_follows_only_its_own_tab_never_another_tab_of_the_shared_profile(monkeypatch, capsys):
    import io
    import types
    foreign = _FPage("https://accounts.google.com/signin/oauth/consent", "Sign in to Claude", ["continue"])    # someone else's flow, in the same Chrome
    own = _FPage("http://localhost:5555/callback")
    ctx = types.SimpleNamespace(listeners=[], new_page=lambda: [fn(foreign) for fn in ctx.listeners] and own or own, on=lambda ev, fn: ctx.listeners.append(fn))
    pw = types.SimpleNamespace(chromium=types.SimpleNamespace(connect_over_cdp=lambda *a, **k: types.SimpleNamespace(contexts=[ctx])))
    mod = types.ModuleType("playwright.sync_api")
    mod.sync_playwright = lambda: types.SimpleNamespace(__enter__=lambda s: pw, __exit__=lambda s, *a: False)
    mod.sync_playwright = lambda: type("SP", (), {"__enter__": lambda s: pw, "__exit__": lambda s, *a: False})()
    monkeypatch.setitem(sys.modules, "playwright", types.ModuleType("playwright"))
    monkeypatch.setitem(sys.modules, "playwright.sync_api", mod)
    monkeypatch.setattr(sys, "stdin", io.StringIO("https://claude.ai/oauth/authorize?x=1"))
    monkeypatch.setenv("RENEW_EMAIL", EMAIL["b85"])
    assert renew.drive() == 0
    assert '"verdict": "ok"' in capsys.readouterr().out
    assert ctx.listeners == [] and own.handlers == ["popup"]                      # no context-wide listener: only popups of our own tab are adopted
    assert foreign.closed is False and foreign.clicks == []                       # the other flow's tab was neither read, clicked nor closed
    assert own.closed is True                                                    # our own tab is closed on the way out


@pytest.mark.parametrize("url, ok", [
    ("https://claude.ai/oauth/authorize?x=1", True), ("https://platform.claude.com/oauth/authorize?x=1", True), ("http://claude.ai/oauth/authorize", False),
    ("https://claude.ai.evil.com/oauth/authorize", False), ("https://evil.com/?u=https://claude.ai/", False), ("file:///etc/passwd", False), ("", False),
    ("https://claude.ai/oauth/authorize\nhttps://evil.com", False),
])
def test_the_driver_only_ever_navigates_to_anthropic(url, ok):
    assert renew.valid_oauth_url(url) is ok


# ── what cannot be automated: the mark, the ONE push, the retries, the hand login (ga-xoe5ao.5.2) ───────────
def script(w, *outs):
    """Make the attempt itself a script (the dance is proven above): each call returns the next (verdict, step, proof)."""
    it = iter(outs)
    w.mp.setattr(renew, "attempt", lambda email, reason, t: next(it))


PROOF = {"svc": "s", "at": T0, "reason": "forced", "before": None, "after": {"afp": "aaaa", "rfp": "rrrr", "rexp": "2099"}, "owner_unverified": False}


def acct(w, key="b85"):
    return w.state()["accounts"][EMAIL[key]]


@pytest.mark.parametrize("verdict", ["puzzle", "needs_device", "wrong_account", "no_google_session", "needs_password"])
def test_a_wall_is_pushed_once_with_the_exact_step_and_never_again_while_it_is_the_same_wall(w, verdict):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, (verdict, "at the page", None), (verdict, "at the page", None))
    assert w.run() == 2 and w.run() == 2
    (n,), m = w.calls("notify"), w.mark()
    assert n["strict"] == "1" and n["argv"][:4] == ["-t", f"Relogin automatico impossivel ({verdict}): {EMAIL['b85']}", "-p", "4"]
    assert (m["verdict"], m["pushed"], m["left"]) == (verdict, T0, pytest.approx(3 * DAY, abs=2))
    assert ("automation Chrome" if verdict in renew.CHROME_FIX else crew.relogin_cmd(EMAIL["b85"])) in n["argv"][4]
    assert m.get("recheck_at") == (T0 + renew.RECHECK_S if verdict in renew.CHROME_FIX else None)
    assert "sk-ant" not in json.dumps(w.state()) + n["argv"][4]


def test_a_push_that_was_not_delivered_is_retried_every_5_minutes_by_the_bare_run_and_never_again_once_delivered(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_NOTIFY_RC", "1")
    script(w, ("puzzle", "s", None))
    w.run()
    assert len(w.calls("notify")) == 1 and "pushed" not in w.mark()
    w.at(renew.PUSH_RETRY_S - 1)
    assert renew.housekeeping() == 0 and len(w.calls("notify")) == 1                         # too soon
    w.at(renew.PUSH_RETRY_S)
    renew.housekeeping()
    assert len(w.calls("notify")) == 2 and "pushed" not in w.mark()
    w.mp.setenv("FAKE_NOTIFY_RC", "10")                                                      # held for 07:00 = delivered
    w.at(2 * renew.PUSH_RETRY_S)
    renew.housekeeping()
    assert len(w.calls("notify")) == 3 and w.mark()["pushed"] == T0 + 2 * renew.PUSH_RETRY_S
    w.at(3 * DAY)
    renew.housekeeping()
    assert len(w.calls("notify")) == 3


@pytest.mark.parametrize("rc, delivered", [(0, True), (10, True), (11, True), (12, False), (1, False)])
def test_only_the_strict_exits_of_notify_count_as_delivered(w, rc, delivered):
    w.mp.setenv("FAKE_NOTIFY_RC", str(rc))
    assert renew.push("t", "x") is delivered and ("was not delivered" in w.log()) is (not delivered)


def test_a_notify_that_cannot_run_is_not_delivered_and_said(w):
    w.mp.setenv("CLAUDE_CREW_NOTIFY", str(w.d / "no-such-notify"))
    assert renew.push("t", "x") is False and "could not run" in w.log()


def test_the_same_wall_is_not_pushed_again_but_a_different_wall_is(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None), ("puzzle", "s", None), ("needs_password", "p", None))
    w.run()
    w.at(3600)
    w.run()
    assert len(w.calls("notify")) == 1 and w.mark()["pushed"] == T0
    w.run()
    assert len(w.calls("notify")) == 2 and w.mark()["verdict"] == "needs_password" and w.mark()["pushed"] == T0 + 3600


def test_three_failed_tries_in_a_row_are_the_same_mark_and_one_push(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, *[("no_full_login", "nothing new", None)] * 3)
    w.run()
    assert (acct(w)["tries"], acct(w)["next_at"], w.mark(), w.calls("notify")) == (1, T0 + renew.RETRY_S, None, [])
    assert "failed try 1 of 3" in capsys.readouterr().out
    w.run()
    assert acct(w)["tries"] == 2 and w.mark() is None
    w.run()
    m = w.mark()
    assert m["verdict"] == "failed_3_times" and m["step"] == "no_full_login: nothing new" and m["pushed"] == T0
    (n,) = w.calls("notify")
    assert "3 automatic tries failed" in n["argv"][4] and crew.relogin_cmd(EMAIL["b85"]) in n["argv"][4]
    assert "marked 'inviavel por automacao'" in capsys.readouterr().out


def test_a_state_write_that_fails_leaves_no_tmp_file_behind(w, monkeypatch):
    def boom(a, b):
        raise OSError(28, "No space left on device")
    monkeypatch.setattr(renew.os, "replace", boom)
    with pytest.raises(OSError):
        renew.publish_state({"accounts": {}})
    assert list(w.d.glob("renew_state.json*")) == []


def test_a_try_that_launched_nothing_is_not_a_failed_try_and_a_proof_clears_the_marks(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("skipped", "unreadable", None), ("puzzle", "s", None), (("renewed", "", PROOF)))
    assert w.run() == 2 and "tries" not in acct(w) and w.mark() is None
    w.run()
    assert w.mark()
    assert w.run() == 0 and w.mark() is None and "tries" not in acct(w) and acct(w)["renewed"]["after"]["rfp"] == "rrrr"
    assert "refresh none -> rrrr" in capsys.readouterr().out                                   # a first login has no "before": said as none, not as None


def test_a_login_made_by_hand_with_a_day_more_life_lifts_the_mark_and_less_does_not(w):
    w.own("b85", blob("b85-old", rexp_days=10.0))                                              # past the 7-day forecast: the bare run only lifts, it does not renew
    script(w, ("puzzle", "s", None))
    w.run()
    w.own("b85", blob("b85-hand-1", rexp_days=10.5))
    renew.housekeeping()
    assert w.mark()
    w.own("b85", blob("b85-hand-2", rexp_days=11.1))
    renew.housekeeping()
    assert w.mark() is None and "logged in by hand" in w.log()


def test_a_mark_stands_while_the_item_cannot_be_read_and_a_mark_with_no_login_at_all_is_lifted_by_the_first_login(w):
    script(w, ("puzzle", "s", None))
    w.run()                                                                                   # no item at all: nothing recorded at the mark (left = None)
    assert w.mark()["left"] is None
    renew.housekeeping()
    assert w.mark()                                                                           # still no login: it stands
    w.own("b85", blob("b85-hand", rexp_days=30.0))
    w.mp.setenv("FAKE_SEC_FAIL", w.svc("b85"))
    renew.housekeeping()
    assert w.mark()                                                                           # a login that cannot be read says nothing
    w.mp.delenv("FAKE_SEC_FAIL")
    renew.housekeeping()
    assert w.mark() is None


@pytest.mark.parametrize("raw", [b"{not json", b"[1, 2]", b'{"accounts": []}', b'{"accounts": {"x": 5}}'])
def test_a_state_file_that_cannot_be_read_is_an_empty_state_and_said(w, raw):
    (w.d / "renew_state.json").write_bytes(raw)
    assert renew.load_state() == ({}, "unreadable") and "unreadable" in w.log()


def test_a_state_path_that_cannot_be_read_is_an_empty_state_and_said_but_no_file_is_a_first_run(w):
    assert renew.load_state() == ({}, "missing") and w.log() == ""
    (w.d / "renew_state.json").mkdir()
    assert renew.load_state() == ({}, "unreadable") and "unreadable" in w.log()


def test_a_state_that_cannot_be_written_is_said_on_the_printed_line_and_the_push_still_goes(w, capsys):
    (w.d / "notadir").write_text("x")
    w.mp.setenv("CLAUDE_RENEW_STATE", str(w.d / "notadir" / "state.json"))
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    assert w.run() == 2
    assert "could not be written" in capsys.readouterr().out and len(w.calls("notify")) == 1


def test_the_bare_run_launches_nothing_and_writes_no_state_when_there_is_nothing_to_do(w):
    w.own("b85", blob("b85-old", rexp_days=14.0))
    assert renew.main([]) == 0 and w.calls("claude") == [] and w.calls("driver") == [] and not (w.d / "renew_state.json").exists()


def test_a_run_that_finds_the_lock_taken_does_nothing_and_a_forced_one_is_not_a_quiet_zero(w):
    import fcntl
    w.own("b85", blob("b85-old", rexp_days=3.0))
    fd = os.open(str(w.d / "city" / ".gc" / "claude-login-renew.lock"), os.O_CREAT | os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        assert renew.main(["--account", EMAIL["b85"], "--force"]) == 2 and renew.main([]) == 0 and w.calls("claude") == []
    finally:
        os.close(fd)


def test_a_claude_that_cannot_run_is_a_failed_try_named_as_such_and_the_item_is_left_alone(w, capsys):
    old = blob("b85-old", rexp_days=3.0)
    w.own("b85", old)
    w.mp.setenv("CLAUDE_RENEW_CLAUDE", str(w.d / "no-such-claude"))
    assert w.run() == 2
    assert "cli_unavailable" in capsys.readouterr().out and w.get(w.svc("b85")) == old and acct(w)["tries"] == 1


# ── the scheduled run: forecast, outage, ONE account per run, waits, controls (ga-xoe5ao.5.3) ──────────────────────
def record(w, *outs):
    """`attempt` replaced by a script that also notes who it was asked for and why; past the script it renews (PROOF)."""
    seen, it = [], iter(outs)

    def fake(email, reason, t):
        seen.append((email, reason))
        return next(it, ("renewed", "", PROOF))
    w.mp.setattr(renew, "attempt", fake)
    return seen


def healthy(w, days=29.0, *keys):
    for k in keys or ("crypto", "b85", "terr", "amb"):
        w.own(k, blob(f"{k}-ok", rexp_days=days))


def outage(w, ago=600, **kw):
    w.crew_state(no_login={"since": T0 - ago}, **kw)


@pytest.mark.parametrize("days, launched", [(7.0, True), (7.1, False), (0.5, True)])
def test_the_forecast_fires_when_the_best_login_ends_within_7_days_and_not_a_minute_later(w, days, launched):
    healthy(w)
    w.own("b85", blob("b85-x", rexp_days=days))
    seen = record(w)
    assert renew.housekeeping() == 0
    assert seen == ([(EMAIL["b85"], "forecast")] if launched else [])


def test_the_best_of_the_accounts_items_counts_and_an_end_that_is_not_recorded_is_not_a_forecast(w):
    healthy(w)
    w.own("b85", blob("b85-own", rexp_days=3.0))
    w.put(crew.reserve_service(EMAIL["b85"]), blob("b85-reserve", rexp_days=20.0))              # the reserve item has a fresher login: the account is not ending
    b = blob("amb-x")
    del b["claudeAiOauth"]["refreshTokenExpiresAt"]
    w.own("amb", b)                                                                             # no end recorded = unknown, not "ends today"
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []


def test_one_account_per_run_the_nearest_end_first_and_the_next_run_takes_the_next(w):
    healthy(w)
    for k, d in (("amb", 6.0), ("b85", 2.0), ("terr", 4.0)):
        w.own(k, blob(f"{k}-x", rexp_days=d))
    seen = record(w)
    renew.housekeeping()
    assert seen == [(EMAIL["b85"], "forecast")]                                                 # three are due, ONE goes
    w.own("b85", blob("b85-new"))                                                               # it was renewed: its login is fresh
    renew.housekeeping()
    w.own("terr", blob("terr-new"))
    renew.housekeeping()
    assert seen == [(EMAIL[k], "forecast") for k in ("b85", "terr", "amb")]


def test_the_account_that_holds_the_default_is_left_out_while_the_default_is_a_full_login_and_only_then(w):
    healthy(w)
    w.own("crypto", blob("crypto-own", rexp_days=2.0))
    w.own("b85", blob("b85-own", rexp_days=3.0))
    w.crew_state(current=EMAIL["crypto"])
    w.default("crypto", blob("crypto-default", rexp_days=25.0))                                 # the default item holds crypto's full login: the rotation keeps it
    seen = record(w)
    renew.housekeeping()
    assert seen == [(EMAIL["b85"], "forecast")]                                                 # b85's own 3 days count; the DEFAULT item (crypto's login) does not count for b85
    assert f"{EMAIL['crypto']} holds the default and it is a full login" in w.log()
    w.default("crypto", {"claudeAiOauth": {"accessToken": "sk-ant-oat01-setup-acc", "expiresAt": int((T0 + DAY) * 1000), "scopes": ["user:inference"]}})
    w.own("b85", blob("b85-new"))                                                               # ... but a default that is NOT a full login (a setup-token) does not excuse it
    renew.housekeeping()
    assert seen[1:] == [(EMAIL["crypto"], "forecast")]


def test_the_default_item_login_counts_for_the_holder_only(w):
    healthy(w)
    w.crew_state(current=EMAIL["crypto"])
    w.own("crypto", blob("crypto-own", rexp_days=2.0))
    w.own("b85", blob("b85-own", rexp_days=2.0))
    w.default("crypto", blob("crypto-default", rexp_days=25.0))
    w.mp.setenv("FAKE_SEC_FAIL", crew.DEFAULT_SERVICE)                                          # the default item cannot be read: the HOLDER is not judged (WARN) ...
    seen = record(w)
    renew.housekeeping()
    assert seen == [(EMAIL["b85"], "forecast")]                                                 # ... and b85, who has nothing on that item, still is
    assert f"{EMAIL['crypto']}: an item could not be read" in w.log()


# ── the outage ──────────────────────────────────────────────────────────────────
def test_an_outage_of_10_minutes_with_no_usable_login_renews_the_pool_pick_first_then_the_others_one_per_run(w):
    outage(w)
    w.decide("amb")
    seen = record(w, ("no_full_login", "nothing new", None))
    renew.housekeeping()
    renew.housekeeping()                                                                        # amb failed (transient): it waits 6 h, the next in line goes
    assert seen == [(EMAIL["amb"], "outage"), (EMAIL["b85"], "outage")]


@pytest.mark.parametrize("what", ["nine_minutes", "ended", "since_not_a_number", "a_usable_login_exists", "an_item_cannot_be_read"])
def test_what_is_not_an_outage_launches_nothing(w, what):
    outage(w)
    if what == "nine_minutes":
        outage(w, ago=599)
    elif what == "ended":
        w.crew_state(no_login={"since": T0 - 3600, "ending": T0 - 10})
    elif what == "since_not_a_number":
        w.crew_state(no_login={"since": "yesterday"})
    elif what == "a_usable_login_exists":
        w.own("terr", blob("terr-ok"))                                                          # the crew job heals the default from it: nothing for us to do
    else:
        w.mp.setenv("FAKE_SEC_FAIL", w.svc("amb"))                                              # we cannot say there is no login anywhere
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []
    if what == "an_item_cannot_be_read":
        assert f"{EMAIL['amb']}: an item could not be read" in w.log()


def test_logins_the_crew_job_has_burned_are_not_usable_so_that_is_an_outage(w):
    healthy(w)
    outage(w, burned={fps(blob(f"{k}-ok"))[1]: {"n": crew.BURN_LIMIT} for k in ("crypto", "b85", "terr", "amb")})
    w.decide("terr")
    seen = record(w)
    renew.housekeeping()
    assert seen == [(EMAIL["terr"], "outage")]


MARTINS_ITEM = "Claude Code-credentials-BACKUP-athosmartins-20261004"                           # athosmartins has no config dir: only a backup item, and the crew job heals from it


def test_a_backup_login_of_an_account_with_no_config_dir_means_there_is_no_outage(w):
    outage(w)                                                                                   # the episode stays open ~10 min after a heal: the heal came from the backup
    w.put(MARTINS_ITEM, blob("martins-ok"))
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []


def test_the_holder_with_no_config_dir_and_a_full_default_login_means_there_is_no_outage(w):
    outage(w, current=EMAIL["martins"])
    w.default("martins", blob("martins-ok"))
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []


def test_a_backup_item_that_cannot_be_read_is_not_an_outage_and_the_log_says_why(w):
    outage(w)
    w.mp.setenv("FAKE_SEC_FAIL", MARTINS_ITEM)
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []
    assert f"{EMAIL['martins']}: an item could not be read" in w.log() and "no outage is judged" in w.log()


def test_a_burned_backup_login_does_not_stop_the_outage_and_the_account_with_no_dir_is_never_tried(w, capsys):
    w.put(MARTINS_ITEM, blob("martins-ok"))
    outage(w, burned={fps(blob("martins-ok"))[1]: {"n": crew.BURN_LIMIT}})
    w.decide("amb")
    seen = record(w)
    renew.housekeeping()
    assert seen == [(EMAIL["amb"], "outage")]
    assert renew.main(["--dry-run"]) == 0 and EMAIL["martins"] not in capsys.readouterr().err


def test_the_forecast_goes_before_the_outage_and_the_dry_run_says_the_whole_order(w, capsys):
    outage(w)
    w.decide("amb")
    w.own("b85", blob("b85-dying", rexp_days=0.5))                                              # 12 h left: not a full login (under a day), but it ENDS within 7 days
    assert renew.main(["--dry-run"]) == 0
    err = capsys.readouterr().err
    assert (f"{EMAIL['b85']}: would be renewed now (forecast) - nothing launched; then, in later runs: "
            f"{EMAIL['amb']}, {EMAIL['crypto']}, {EMAIL['terr']}") in err


# ── waits and marks ──────────────────────────────────────────────────────────────
def test_a_failed_try_waits_6_hours_and_the_third_in_a_row_marks_the_account_with_ONE_push(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    healthy(w, 29.0, "crypto", "terr", "amb")
    seen = record(w, *[("no_full_login", "nothing new", None)] * 3)
    renew.housekeeping()
    w.at(renew.RETRY_S - 1)
    renew.housekeeping()
    assert len(seen) == 1                                                                       # too soon
    for n in (1, 2):
        w.at(n * renew.RETRY_S)
        renew.housekeeping()
    assert len(seen) == 3 and w.mark()["verdict"] == "failed_3_times"
    w.at(10 * renew.RETRY_S)
    renew.housekeeping()
    assert len(seen) == 3 and len(w.calls("notify")) == 1                                       # marked: no 4th try, ONE push


def test_a_wall_is_not_retried_by_the_schedule_and_a_browser_fix_is_looked_at_again_after_24_hours(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    healthy(w, 90.0, "crypto", "terr", "amb")                                                    # they outlive the 31 days this test jumps
    seen = record(w, ("puzzle", "s", None))
    renew.housekeeping()
    w.at(30 * DAY)
    renew.housekeeping()
    assert len(seen) == 1 and len(w.calls("notify")) == 1                                       # a puzzle waits for a human, however late
    w.own("terr", blob("terr-old", rexp_days=3.0))
    seen = record(w, ("no_google_session", "s", None), ("no_google_session", "s", None))
    w.at(31 * DAY)
    renew.housekeeping()
    assert seen == [(EMAIL["terr"], "forecast")] and acct(w, "terr")["infeasible"]["recheck_at"] == T0 + 31 * DAY + renew.RECHECK_S
    w.at(31 * DAY + renew.RECHECK_S - 1)
    renew.housekeeping()
    assert len(seen) == 1                                                                       # not yet
    w.at(31 * DAY + renew.RECHECK_S)
    renew.housekeeping()
    assert len(seen) == 2 and len(w.calls("notify")) == 2                                       # looked at again; the same wall: no new push (b85's + terr's only)


@pytest.mark.parametrize("rec", [{"infeasible": "yes"}, {"infeasible": {"verdict": "puzzle"}}, {"infeasible": {"verdict": "puzzle", "left": 3 * DAY}}, {"next_at": "soon"}, {"next_at": True},
                                 {"infeasible": {"verdict": "no_google_session", "left": 3 * DAY, "recheck_at": "later"}}, {"infeasible": {"verdict": "no_google_session", "recheck_at": "later"}}])
def test_a_record_that_cannot_be_read_keeps_the_account_untouched(w, rec):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    healthy(w, 29.0, "crypto", "terr", "amb")
    (w.d / "renew_state.json").write_text(json.dumps({"accounts": {EMAIL["b85"]: rec}}))
    seen = record(w)
    assert renew.housekeeping() == 0 and seen == []
    if "next_at" in rec:
        assert "next_at is not a number" in w.log()
    if rec.get("infeasible") == "yes":
        assert f"{EMAIL['b85']}: the mark is not an object" in w.log()
    if isinstance(rec.get("infeasible"), dict) and rec["infeasible"].get("recheck_at") == "later":
        assert f"{EMAIL['b85']}: the mark's recheck_at is not a number" in w.log()
    if isinstance(rec.get("infeasible"), dict) and "left" not in rec["infeasible"]:
        assert "the mark has no `left`" in w.log()


def test_a_wall_waiting_for_a_hand_login_or_its_recheck_is_quiet_in_the_log(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    w.run()
    w.own("amb", blob("amb-old", rexp_days=3.0))
    script(w, ("no_google_session", "s", None))
    w.run("amb")
    before = w.log()
    renew.housekeeping()
    new = w.log()[len(before):]
    assert "not an object" not in new and "not a number" not in new                                # only a record the job cannot READ is worth a line every 15 minutes


def test_the_mark_dates_the_end_of_the_login_as_of_the_moment_it_was_marked_not_the_moment_the_attempt_began(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))

    def slow(email, reason, t):
        w.at(300)                                                                               # the attempt took 5 minutes
        return "puzzle", "at claude.ai/oauth/authorize", None
    w.mp.setattr(renew, "attempt", slow)
    w.run()
    m = w.mark()
    assert m["at"] == T0 + 300 and m["at"] + m["left"] == pytest.approx(T0 + 3 * DAY, abs=1)


def test_a_mark_stands_and_says_so_while_an_item_of_the_account_cannot_be_read(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    w.run()
    w.own("b85", blob("b85-hand", rexp_days=30.0))
    w.mp.setenv("FAKE_SEC_FAIL", crew.reserve_service(EMAIL["b85"]))
    renew.housekeeping()
    assert w.mark() and "the mark stands until it can be" in w.log()


# ── controls ──────────────────────────────────────────────────────────────────
def test_a_forced_dry_run_says_it_would_be_skipped_when_an_item_of_the_account_cannot_be_read(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("FAKE_SEC_FAIL", crew.reserve_service(EMAIL["b85"]))
    assert renew.main(["--dry-run", "--account", EMAIL["b85"], "--force"]) == 0
    err = capsys.readouterr().err
    assert "would be SKIPPED" in err and "would renew it now" not in err and w.calls("claude") == []


def test_without_a_city_the_file_switch_cannot_be_looked_at_and_the_run_says_so_while_the_env_switch_still_works(w, capsys):
    w.mp.delenv("GC_CITY_PATH")
    w.own("b85", blob("b85-old", rexp_days=3.0))
    seen = record(w)
    assert renew.main([]) == 0 and seen == [(EMAIL["b85"], "forecast")]
    assert "GC_CITY_PATH is not set: the file switch" in capsys.readouterr().err
    w.mp.setenv("GC_LOGIN_RENEW", "0")
    assert renew.main([]) == 0 and seen == [(EMAIL["b85"], "forecast")] and "switched off" in capsys.readouterr().err


@pytest.mark.parametrize("how", ["file", "env"])
def test_the_off_switch_stops_the_scheduled_and_the_forced_run_and_putting_it_back_needs_no_reload(w, how, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    seen = record(w)
    sw = w.d / "city" / ".gc" / "no-login-renew"
    if how == "file":
        sw.write_text("")
    else:
        w.mp.setenv("GC_LOGIN_RENEW", "0")
    assert renew.main([]) == 0 and seen == [] and "switched off" in w.log()
    assert renew.main(["--account", EMAIL["b85"], "--force"]) == 2 and seen == [] and "switched off" in capsys.readouterr().err
    assert not (w.d / "renew_state.json").exists() and w.calls("notify") == []
    sw.unlink(missing_ok=True)
    w.mp.delenv("GC_LOGIN_RENEW", raising=False)
    assert renew.main([]) == 0 and seen == [(EMAIL["b85"], "forecast")]


@pytest.mark.parametrize("val", ["1", "", "off", "false"])
def test_only_a_zero_switches_it_off(w, val):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    w.mp.setenv("GC_LOGIN_RENEW", val)
    seen = record(w)
    assert renew.main([]) == 0 and seen == [(EMAIL["b85"], "forecast")]


def test_a_dry_run_says_what_it_would_do_and_launches_writes_and_pushes_nothing(w, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    (w.d / "renew_state.json").write_text(json.dumps({"accounts": {EMAIL["terr"]: {"infeasible": {"verdict": "puzzle", "step": "s", "at": T0, "left": 5.0}}}}))
    before = (w.d / "renew_state.json").read_bytes()
    seen = record(w)
    assert renew.main(["--dry-run"]) == 0
    err = capsys.readouterr().err
    assert f"{EMAIL['b85']}: would be renewed now (forecast) - nothing launched" in err and "[dry-run]" in err
    assert seen == [] and w.calls("claude") == [] and w.calls("notify") == []                    # the pending push of terr's mark was NOT sent
    assert (w.d / "renew_state.json").read_bytes() == before and w.log() == ""                  # no state written, no log file: stderr only
    assert renew.main(["--dry-run", "--account", EMAIL["b85"], "--force"]) == 0
    assert "would renew it now (forced) - nothing launched" in capsys.readouterr().err and seen == []


@pytest.mark.parametrize("argv", [["--account", EMAIL["b85"]], ["--force"], ["--bogus"], ["--dry-run", "--account", EMAIL["b85"]], ["--dry-run", "--bogus"]])
def test_arguments_that_are_not_a_run_are_a_usage_error_and_launch_nothing(w, argv):
    seen = record(w)
    assert renew.main(argv) == 64 and seen == []


# ── what the run cannot know, it does not act on ─────────────────────────────────────
@pytest.mark.parametrize("raw", [b"{not json", b"[1]", b'{"accounts": []}'])
def test_an_unreadable_state_launches_pushes_and_writes_nothing_and_the_exit_says_so(w, raw):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    (w.d / "renew_state.json").write_bytes(raw)
    seen = record(w)
    assert renew.housekeeping() == 1 and seen == [] and w.calls("notify") == []
    assert (w.d / "renew_state.json").read_bytes() == raw and "nothing launched, pushed or written" in w.log()


@pytest.mark.parametrize("how", ["missing", "corrupt", "unreadable"])
def test_a_crew_state_that_cannot_be_read_judges_no_login_but_the_pending_pushes_still_go(w, how, capsys):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    w.mp.setenv("FAKE_NOTIFY_RC", "1")
    w.run()                                                                                      # a mark whose push was not delivered
    assert len(w.calls("notify")) == 1
    p = w.d / "crew_state.json"
    if how == "missing":
        p.unlink()
    elif how == "corrupt":
        p.write_text("{nope")
    else:
        p.unlink()
        p.mkdir()
    w.mp.setenv("FAKE_NOTIFY_RC", "0")
    w.at(renew.PUSH_RETRY_S)
    seen = record(w)
    assert renew.housekeeping() == 1 and seen == []                                              # exit 1 = it could not judge
    assert f"the crew state {p} is {how}" in w.log() and len(w.calls("notify")) == 2 and w.mark()["pushed"]
    assert renew.run_once(EMAIL["b85"]) == 2 and f"is {how}, so whether this account holds the default is unknown" in capsys.readouterr().err and seen == []


def test_a_forced_run_does_not_launch_when_an_item_that_decides_who_holds_the_default_cannot_be_read(w, capsys):
    w.own("crypto", blob("crypto-own", rexp_days=3.0))
    w.crew_state(current=EMAIL["crypto"])
    w.mp.setenv("FAKE_SEC_FAIL", crew.DEFAULT_SERVICE)
    assert w.run("crypto") == 2
    assert w.calls("claude") == [] and "could not be read, so its login is not judged - nothing launched" in capsys.readouterr().out
    assert "tries" not in acct(w, "crypto")                                                      # nothing launched = not a failed try


def test_a_state_that_cannot_be_written_in_the_scheduled_run_is_said_and_the_exit_is_1(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    seen = record(w)

    def boom(st):
        raise PermissionError("read-only")
    w.mp.setattr(renew, "publish_state", boom)
    assert renew.housekeeping() == 1 and seen == [(EMAIL["b85"], "forecast")]
    assert "the state could not be written (PermissionError)" in w.log()


def test_a_lock_that_cannot_be_taken_and_a_run_that_crashes_exit_1_and_say_why(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
    seen = record(w)
    lock = w.d / "city" / ".gc" / "claude-login-renew.lock"
    lock.mkdir()                                                                                 # opening a directory for writing: an OSError that is not "lock held"
    assert renew.main([]) == 1 and renew.main(["--account", EMAIL["b85"], "--force"]) == 1 and seen == []
    assert "cannot take the lock (IsADirectoryError)" in w.log()
    lock.rmdir()

    def boom(*a):
        raise ValueError("boom")
    w.mp.setattr(renew, "candidates", boom)
    assert renew.main([]) == 1 and "run failed (ValueError: boom)" in w.log() and seen == []
    w.mp.setattr(renew, "attempt", boom)
    assert renew.main(["--account", EMAIL["b85"], "--force"]) == 1 and w.log().count("run failed (ValueError: boom)") == 2


# ── the launchd plist (ga-xoe5ao.5.3) ──────────────────────────────────────────────
ASSETS = HERE.parents[1] / "packs" / "town-deltas" / "assets"
PLIST = ASSETS / "pending-activation" / "claude-login-renew.plist"


def test_the_plist_parses_strictly_has_its_own_label_runs_the_bare_script_every_15_minutes_and_names_the_switch():
    import plistlib
    text = PLIST.read_text()
    d = plistlib.loads(text.encode())                                                          # expat, strict: a double hyphen inside a comment fails here (the pre-push lint refused one)
    assert d["Label"] == "com.gascity.claude-login-renew" and d["Label"] != "com.gascity.claude-account-relog"
    assert d["StartInterval"] == 900 and d["RunAtLoad"] is False
    assert d["ProgramArguments"][0] == "/usr/bin/python3" and len(d["ProgramArguments"]) == 2    # the bare script: no --force, no --account
    assert d["ProgramArguments"][1].endswith("packs/town-deltas/assets/scripts/claude-login-renew.py") and SCRIPT.is_file()
    env = d["EnvironmentVariables"]
    assert {"PATH", "HOME", "USER", "GC_CITY_PATH"} <= set(env) and ".local/bin" in env["PATH"]
    assert ".gc/no-login-renew" in text and "GC_LOGIN_RENEW=0" in text                          # the switch the comment names is the one the script reads


def test_the_plist_is_not_where_the_deploy_installs_new_plists_on_its_own():
    import re
    top = {m.group(1) for p in ASSETS.glob("*.plist") for m in [re.search(r"<key>Label</key>\s*<string>([^<]+)</string>", p.read_text())] if m}
    assert "com.gascity.claude-login-renew" not in top and PLIST.parent.name == "pending-activation"
    assert "skill-integrity-install.sh" in PLIST.read_text()                                    # and the file says why
