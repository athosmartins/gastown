"""ga-xy0916u — claude-credential-map.py: which credential each role runs on (full login / 1-year setup-token / the default login / no Claude),
and when each account's setup-token ends (DATES ONLY, read from the vault item; the token never leaves the reader).

No network, no real `gc`, no real vault: the resolved config is a TOML snapshot (CLAUDE_CRED_MAP_CONFIG) and the vault is a loopback server answering what `bw serve` answers.
"""
import http.server
import importlib.util
import json
import threading
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "packs" / "town-deltas" / "assets" / "scripts" / "claude-credential-map.py"
spec = importlib.util.spec_from_file_location("claude_credential_map_under_test", SCRIPT)
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
DAY = 86400
T0 = 1_800_000_000.0


def iso(ts):
    return M.iso(ts)


CONFIG = """
[workspace]
provider = "claude"

[providers.claude-rc]
command = "claude"
[providers.claude-rc-mayor]
command = "claude"
[providers.claude-headless]
command = "claude"

[[agent]]
name = "mayor"
provider = "claude-rc-mayor"
[[agent]]
name = "crew-a"
provider = "claude-rc"
dir = "gastown"
[[agent]]
name = "dog"
provider = "claude-headless"
[[agent]]
name = "wa-worker"
provider = "claude-headless"
dir = "whatsapp_automation"
[[agent]]
name = "polecat"
dir = "gastown"
[[agent]]
name = "witness"
dir = "lexbh"
suspended = true
[[agent]]
name = "control-dispatcher"
start_command = "true"
[[agent]]
name = "scripted"
command = "true"
[[agent]]
name = "kimi-thing"
provider = "kimi"
[[agent]]
name = "claude-headless"
provider = "claude-headless"
"""


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    p = tmp_path / "config.toml"
    p.write_text(CONFIG)
    monkeypatch.setenv("CLAUDE_CRED_MAP_CONFIG", str(p))
    return p


def by_role(rs):
    return {(r["rig"], r["role"]): r for r in rs}


def test_every_role_is_classified_by_the_credential_it_runs_on(cfg):
    rs = by_role(M.roles(M.load_config()))
    assert rs[("", "mayor")]["credential"] == M.FULL
    assert rs[("gastown", "crew-a")]["credential"] == M.FULL
    assert rs[("", "dog")]["credential"] == M.TOKEN and rs[("whatsapp_automation", "wa-worker")]["credential"] == M.TOKEN
    assert rs[("gastown", "polecat")]["credential"] == M.DEFAULT and "workspace default" in rs[("gastown", "polecat")]["provider"]
    assert rs[("", "control-dispatcher")]["credential"] == M.NO_CLAUDE        # start_command: no Claude at all
    assert rs[("", "scripted")]["credential"] == M.NO_CLAUDE                  # command: no Claude at all
    assert rs[("", "kimi-thing")]["credential"] == M.NO_CLAUDE                # another vendor
    assert ("", "claude-headless") not in rs                                  # the agent the engine synthesizes from a provider is not a role


def test_roles_are_sorted_full_then_token_then_default_then_none(cfg):
    order = [r["credential"] for r in M.roles(M.load_config())]
    assert order == sorted(order, key={M.FULL: 0, M.TOKEN: 1, M.DEFAULT: 2, M.NO_CLAUDE: 3}.get)


def test_a_workspace_default_provider_that_is_headless_makes_the_unpinned_roles_token_roles(tmp_path, monkeypatch):
    p = tmp_path / "c.toml"
    p.write_text('[workspace]\nprovider = "claude-headless"\n[[agent]]\nname = "x"\n')
    monkeypatch.setenv("CLAUDE_CRED_MAP_CONFIG", str(p))
    assert [r["credential"] for r in M.roles(M.load_config())] == [M.TOKEN]


def test_check_exits_3_and_names_the_live_unpinned_roles_not_the_suspended_ones(cfg, capsys):
    assert M.main(["check"]) == 3
    err = capsys.readouterr().err
    assert "gastown/polecat" in err and "lexbh/witness" not in err           # the suspended one is not live


def test_check_exits_0_when_every_live_role_is_pinned(tmp_path, monkeypatch, capsys):
    p = tmp_path / "c.toml"
    p.write_text('[workspace]\nprovider = "claude"\n[[agent]]\nname = "d"\nprovider = "claude-headless"\n[[agent]]\nname = "u"\nsuspended = true\n')
    monkeypatch.setenv("CLAUDE_CRED_MAP_CONFIG", str(p))
    assert M.main(["check"]) == 0 and capsys.readouterr().err == ""


def test_an_unreadable_config_is_exit_1_and_said_not_an_empty_map(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CLAUDE_CRED_MAP_CONFIG", str(tmp_path / "nope.toml"))
    assert M.main(["roles"]) == 1 and "could not be read" in capsys.readouterr().err
    (tmp_path / "bad.toml").write_text("this is [not toml")
    monkeypatch.setenv("CLAUDE_CRED_MAP_CONFIG", str(tmp_path / "bad.toml"))
    assert M.main(["check"]) == 1


def test_roles_text_and_json(cfg, capsys):
    assert M.main(["roles"]) == 0
    out = capsys.readouterr().out
    assert "FULL LOGIN" in out and "1-YEAR SETUP-TOKEN" in out and "gastown/polecat" in out and "(suspended)" in out
    assert M.main(["roles", "--json"]) == 0
    assert {r["credential"] for r in json.loads(capsys.readouterr().out)} == {M.FULL, M.TOKEN, M.DEFAULT, M.NO_CLAUDE}


@pytest.mark.parametrize("argv", [[], ["nope"], ["roles", "check"]])
def test_usage_is_64(argv, capsys):
    assert M.main(argv) == 64


# ── the vault: dates only ─────────────────────────────────────────────────────────────────────
class Vault:
    """A loopback `bw serve`: answers `GET /list/object/items?search=…` with `body` (or raw text)."""

    def __init__(self, monkeypatch):
        self.body, self.raw, self.paths = [], None, []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.paths.append(self.path)
                data = outer.raw if outer.raw is not None else json.dumps({"success": True, "data": {"object": "list", "data": outer.body}})
                self.send_response(200)
                self.end_headers()
                self.wfile.write(data.encode())

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        monkeypatch.setenv("CLAUDE_CRED_BW_URL", f"http://127.0.0.1:{self.srv.server_address[1]}")

    def item(self, email, *, notes="sk-ant-oat01-SECRETSECRET", revision=None, creation=None, gerado=None, **extra):
        it = {"name": M.ITEM_PREFIX + email, "notes": notes, "revisionDate": revision, "creationDate": creation,
              "fields": [{"name": "gerado_em", "value": gerado, "type": 0}] if gerado else [], **extra}
        self.body.append(it)
        return it


@pytest.fixture
def vault(monkeypatch):
    v = Vault(monkeypatch)
    yield v
    v.srv.shutdown()


def test_the_vault_is_asked_only_for_the_token_items_and_the_answer_keeps_dates_never_the_token(vault):
    vault.item("A@X.com", revision=iso(T0))
    status, items = M.vault_tokens()
    assert status == "ok" and vault.paths == ["/list/object/items?search=claude-oauth-token-"]
    assert items == {"a@x.com": {"generated": T0, "source": "revisionDate", "has_token": True}}
    assert "SECRETSECRET" not in json.dumps(items)


def test_gerado_em_wins_over_revisionDate_and_creationDate(vault):
    vault.item("a@x.com", revision=iso(T0), creation=iso(T0 - 9 * DAY), gerado=iso(T0 - 100 * DAY))
    assert M.vault_tokens()[1]["a@x.com"] == {"generated": T0 - 100 * DAY, "source": "gerado_em", "has_token": True}


def test_creationDate_is_used_when_there_is_no_revisionDate_and_a_bad_date_is_no_date(vault):
    vault.item("a@x.com", creation=iso(T0 - DAY))
    vault.item("b@x.com", revision="not a date", creation=None)
    vault.item("c@x.com", gerado="garbage", revision=iso(T0))                  # a gerado_em nobody can read falls back to the item's own date
    items = M.vault_tokens()[1]
    assert items["a@x.com"]["source"] == "creationDate" and items["b@x.com"]["generated"] is None and items["c@x.com"]["source"] == "revisionDate"


def test_items_of_other_kinds_deleted_items_and_nameless_ones_are_not_accounts(vault):
    vault.body += [{"name": "something-else-a@x.com"}, {"name": M.ITEM_PREFIX}, {"name": 7}, "junk", None]
    vault.item("gone@x.com", revision=iso(T0), deletedDate=iso(T0))
    vault.item("ok@x.com", revision=iso(T0))
    assert list(M.vault_tokens()[1]) == ["ok@x.com"]


def test_an_item_with_no_token_in_it_is_there_but_has_no_token(vault):
    vault.item("a@x.com", notes="   ", revision=iso(T0))
    vault.item("b@x.com", notes=None, revision=iso(T0))
    assert [v["has_token"] for v in M.vault_tokens()[1].values()] == [False, False]


def test_an_empty_vault_is_ok_and_empty(vault):
    assert M.vault_tokens() == ("ok", {})


@pytest.mark.parametrize("raw", ["<html>nonsense</html>", "[]", '{"data": 3}', '{"data": {"data": "x"}}', "null", ""])
def test_an_answer_that_is_not_a_list_of_items_is_unreadable_not_empty(vault, raw):
    vault.raw = raw
    assert M.vault_tokens() == ("unreadable", {})


def test_a_vault_that_does_not_answer_is_unreachable(monkeypatch):
    monkeypatch.setenv("CLAUDE_CRED_BW_URL", "http://127.0.0.1:9")
    assert M.vault_tokens(timeout=2) == ("unreachable", {})


def test_token_state_none_empty_undated_ok_and_the_life(monkeypatch):
    assert M.token_state(None, T0)["state"] == "none"
    assert M.token_state({"generated": T0, "source": "x", "has_token": False}, T0)["state"] == "empty"
    assert M.token_state({"generated": None, "source": None, "has_token": True}, T0)["state"] == "undated"
    s = M.token_state({"generated": T0 - 65 * DAY, "source": "revisionDate", "has_token": True}, T0)
    assert s["state"] == "ok" and s["end"] == T0 + 300 * DAY and s["left"] == 300 * DAY
    monkeypatch.setenv("CLAUDE_CRED_TOKEN_LIFE_S", str(10 * DAY))
    assert M.token_state({"generated": T0 - 4 * DAY, "source": "x", "has_token": True}, T0)["left"] == 6 * DAY
    monkeypatch.setenv("CLAUDE_CRED_TOKEN_LIFE_S", "garbage")
    assert M.token_life_s() == 365 * DAY


@pytest.mark.parametrize("left_d, want", [(None, None), (22, None), (21, 21), (20.9, 21), (7, 7), (6.9, 7), (1, 1), (0.1, 1), (0, 0), (-3, 0)])
def test_level_is_the_tightest_threshold_crossed_zero_when_ended_and_nothing_when_unknown_or_far(left_d, want):
    left = None if left_d is None else left_d * DAY
    got = M.level(left, M.TOKEN_WARN_S)
    assert got == (None if want is None else want * DAY if want else 0)


def test_the_login_thresholds_are_7_3_1_days_and_the_first_word_is_at_least_3_days_ahead():
    assert M.LOGIN_WARN_S == (7 * DAY, 3 * DAY, 1 * DAY) and max(M.LOGIN_WARN_S) >= 3 * DAY
    assert M.level(6.9 * DAY, M.LOGIN_WARN_S) == 7 * DAY and M.level(7.1 * DAY, M.LOGIN_WARN_S) is None


def test_the_tokens_command_prints_dates_only(vault, capsys):
    vault.item("a@x.com", revision=iso(M.time.time() - 65 * DAY))
    vault.item("b@x.com", notes="")
    assert M.main(["tokens"]) == 0
    out = capsys.readouterr().out
    assert "a@x.com: token ok, ends " in out and "b@x.com: token empty" in out and "SECRETSECRET" not in out and "sk-ant" not in out
    assert M.main(["tokens", "--json"]) == 0
    rows = json.loads(capsys.readouterr().out)
    assert rows["a@x.com"]["state"] == "ok" and "SECRETSECRET" not in json.dumps(rows)


def test_the_tokens_command_exits_1_when_the_vault_cannot_be_read(monkeypatch, capsys):
    monkeypatch.setenv("CLAUDE_CRED_BW_URL", "http://127.0.0.1:9")
    assert M.main(["tokens"]) == 1 and "could not be read (unreachable)" in capsys.readouterr().err
