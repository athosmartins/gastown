"""ga-qdtmq2 — claude-crew-account.py: the Mayor's and the crews' Claude account follows the pool decision, LIVE.

Every test runs against a FAKE `security` (a json store; it logs every argv so we can prove no secret rides on a command
line) and a loopback profile server. Nothing here touches the real Keychain or the network.
"""
import http.server
import importlib.util
import json
import os
import stat
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

NOTIFY = "#!/bin/sh\necho \"$@\" >> \"$FAKE_SEC_DIR/notify.log\"\n"
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
        o["refreshTokenExpiresAt"] = int((now + rexp_days * 86400) * 1000)
    return {"claudeAiOauth": o}


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
            p.write_text(body)
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.d / "city" / ".gc" / "logs").mkdir(parents=True)
        (self.d / "sessions").mkdir()
        self.now = time.time()
        for k, v in {
            "FAKE_SEC_DIR": str(self.d), "CLAUDE_CREW_SECURITY": str(self.d / "security"),
            "CLAUDE_CREW_NOTIFY": str(self.d / "notify"), "CLAUDE_CREW_STATE": str(self.d / "crew_state.json"),
            "CLAUDE_CREW_DECISION": str(self.d / "pool_decision.json"), "CLAUDE_CREW_SESSIONS_DIR": str(self.d / "sessions"),
            "CLAUDE_CREW_ACCOUNTS_DIR": str(self.d / "accts"), "CLAUDE_CREW_USER": "athos", "GC_CITY_PATH": str(self.d / "city"),
            "CLAUDE_CREW_PROFILE_URL": f"http://127.0.0.1:{self.srv.server_address[1]}/profile", "CLAUDE_CREW_NOW": str(self.now),
        }.items():
            monkeypatch.setenv(k, v)
        for k in ("GC_CREW_ACCOUNT", "CLAUDE_CREW_ACCOUNTS", "FAKE_SEC_FAIL"):
            monkeypatch.delenv(k, raising=False)
        self.mp = monkeypatch

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

    def account(self, key, b):
        """An account's own stored login + who the profile says its access token belongs to."""
        self.put(self.src_service(key), b)
        self.tokens[b["claudeAiOauth"]["accessToken"]] = EMAIL[key]

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


def test_a_source_that_belongs_to_someone_else_is_refused(w):
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
