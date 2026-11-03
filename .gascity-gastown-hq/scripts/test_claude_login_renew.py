"""ga-xoe5ao.5.1/.5.2 — claude-login-renew.py, slices 1-2: `--account <e> --force` renews ONE Claude account's login through gmail-totp + the Chrome CDP,
and what the automation does not get around becomes a mark in the state plus ONE push (the "what cannot be automated" block at the end of the file).

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

EMAIL = {"crypto": "athoscrypto@gmail.com", "b85": "athosb85@gmail.com", "martins": "athosmartins@gmail.com"}
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
                 "CLAUDE_RENEW_STATE": tmp_path / "pinned-renew-state.json"}.items():
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
                     "CLAUDE_CREW_NOTIFY": str(self.d / "notify"), "CLAUDE_RENEW_STATE": str(self.d / "renew_state.json"),
                     "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
                     "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(T0)}.items():
            monkeypatch.setenv(k, v)
        for k in ("CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL", "FAKE_CLAUDE_MODE", "FAKE_DRIVER_VERDICT", "FAKE_CLAUDE_BLOB", "FAKE_NOTIFY_RC"):
            monkeypatch.delenv(k, raising=False)
        self.mp = monkeypatch
        assert str(crew.security_bin()).startswith(str(self.d)) and str(crew.city()).startswith(str(self.d))

    def store(self):
        p = self.d / "store.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def own(self, key, b):
        s = self.store()
        s[self.svc(key)] = {"acct": "athos", "secret": json.dumps(b)}
        (self.d / "store.json").write_text(json.dumps(s))

    def get(self, service):
        v = self.store().get(service)
        return json.loads(v["secret"]) if v else None

    def svc(self, key):
        return crew.dir_service(str(self.d / "accts" / {"crypto": "athoscrypto", "b85": "athosb85"}[key]))

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
    assert w.calls("claude") == [] and w.calls("driver") == [] and "cannot be put back" in capsys.readouterr().out


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
           "FAKE_DRIVER_VERDICT": "puzzle", "CLAUDE_CREW_PROFILE_URL": os.environ["CLAUDE_CREW_PROFILE_URL"]}
    r = subprocess.run([py, str(SCRIPT), "--account", EMAIL["b85"], "--force"], env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 2 and "puzzle" in r.stdout, r.stderr


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
    assert n["strict"] == "1" and n["argv"][:4] == ["-t", f"Relogin automatico impossivel: {EMAIL['b85']}", "-p", "4"]
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
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    w.run()
    w.own("b85", blob("b85-hand-1", rexp_days=3.5))
    renew.housekeeping()
    assert w.mark()
    w.own("b85", blob("b85-hand-2", rexp_days=4.1))
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
    assert renew.load_state() == {} and "unreadable" in w.log()


def test_a_state_path_that_cannot_be_read_is_an_empty_state_and_said_but_no_file_is_a_first_run(w):
    assert renew.load_state() == {} and w.log() == ""
    (w.d / "renew_state.json").mkdir()
    assert renew.load_state() == {} and "unreadable" in w.log()


def test_a_state_that_cannot_be_written_is_said_on_the_printed_line_and_the_push_still_goes(w, capsys):
    (w.d / "notadir").write_text("x")
    w.mp.setenv("CLAUDE_RENEW_STATE", str(w.d / "notadir" / "state.json"))
    w.own("b85", blob("b85-old", rexp_days=3.0))
    script(w, ("puzzle", "s", None))
    assert w.run() == 2
    assert "could not be written" in capsys.readouterr().out and len(w.calls("notify")) == 1


def test_the_bare_run_launches_nothing_and_writes_no_state_when_there_is_nothing_to_keep(w):
    w.own("b85", blob("b85-old", rexp_days=3.0))
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
