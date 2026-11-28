#!/usr/bin/env python3
"""claude-credential-map — ga-xy0916u: which credential each role runs on, and when each setup-token ends.

    claude-credential-map.py roles [--json]    every agent of the resolved config, grouped by the credential it runs on
    claude-credential-map.py check             exit 0 = every live role is pinned to a provider; 3 = some live role runs on the unpinned default login (listed)
    claude-credential-map.py tokens [--json]   the vault's `claude-oauth-token-<email>` items: when each token was generated and when it ends (DATES ONLY)
    exit: 0 ok, 3 `check` found unpinned live roles, 1 the config or the vault could not be read (said on stderr), 64 usage

THE RULE (Athos, 28/11, ga-xoe5ao.6: «Token de 1 ano + você só onde precisa»):
  * `claude-rc*` providers (Mayor + the named crews, Remote Control)  -> FULL LOGIN (scope user:sessions:claude_code + refresh token). A setup-token cannot do Remote Control.
  * `claude-headless` (dogs, wa-worker, ps-worker, the reviewers, refino, boot, deacon...) -> the 1-YEAR SETUP-TOKEN (`claude setup-token`, scope user:inference). The pool
    daemon (claude-pool-account.py) puts the vault's token of the account in the pool Keychain item that claude-lowprio.sh points these sessions at.
  * no provider (the workspace default `claude`) -> DEFAULT LOGIN: the same login as the Mayor's. Nothing pins it; `check` lists those so somebody decides.
A role that has an explicit `command`/`start_command` (the control dispatchers) runs no Claude at all.

SOURCE OF THE MAP: `gc config show` (the RESOLVED config: pack agents and city patches together). CLAUDE_CRED_MAP_CONFIG = a path to a TOML file of the same shape (tests, snapshots).
`roles` and `check` need Python 3.11+ (tomllib; the system python3 of the mini is 3.9: exit 1 and says so); `tokens` and the vault dates (claude-login-renew.py) run on 3.9.

THE TOKEN'S END is NOT in the token (it is opaque). It is the vault item's `gerado_em` field (an ISO date, when the item has one) else the item's revisionDate (the day the
token was last stored: registration writes the item once per token) + TOKEN_LIFE_S (365 days, what `claude setup-token` says; not measured here). The token itself never
leaves this process, and never reaches a log, argv, a file or stdout: the vault answer is read for name/dates/fields only and `notes` is reduced to "is there one".
SEAMS (tests): CLAUDE_CRED_MAP_CONFIG, CLAUDE_CRED_BW_URL (default http://127.0.0.1:18587: the local `bw serve` that `secret` waits for after a boot, the same `BW` as lib/contatos_corretor_credencial.py
and the item name of lib/claude_account_pool.py in whatsapp_automation - read there, origin/main of 28/11), CLAUDE_CRED_TOKEN_LIFE_S, CLAUDE_CRED_GC (the gc binary).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
DAY = 86400
ITEM_PREFIX = "claude-oauth-token-"                            # the vault item of an account's token: lib/claude_account_pool.py (whatsapp_automation) names it the same
TOKEN_LIFE_S = 365 * DAY                                       # `claude setup-token`: "valid for one year". Not measured here (a token is only ever tried, never decoded)
TOKEN_WARN_S = (21 * DAY, 7 * DAY, 1 * DAY)                    # the token is Athos's ~2 min step: asked early, then again closer
LOGIN_WARN_S = (7 * DAY, 3 * DAY, 1 * DAY)                     # a full login lasts ~30 days and costs a human step each time: the first word comes 7 days ahead (the rule is >= 3), then 3 and 1
FULL, TOKEN, DEFAULT, NO_CLAUDE = "full-login", "token", "default-login", "no-claude"


def city_root() -> Path:
    return HERE.parents[3]                                     # scripts -> assets -> town-deltas -> packs -> the city


def kind_of(agent: dict, providers: dict, workspace_provider: str) -> str:
    """The credential a role runs on. An explicit `command` (not a provider) is no Claude; no provider is the workspace default."""
    p = agent.get("provider")
    if not p and (agent.get("command") or agent.get("start_command")):
        return NO_CLAUDE
    p = p or workspace_provider
    if p == "claude-headless":
        return TOKEN
    if p == "claude-rc" or p.startswith("claude-rc-"):
        return FULL
    if p.startswith("claude"):                                 # `claude` and any other claude-* the two lines above did not name: the default login, so `check` lists it (never hidden as "no Claude")
        return DEFAULT
    return NO_CLAUDE                                           # hybrid, kimi, codex...: not a Claude login


def load_config() -> dict:
    """The resolved config (dict). Raises OSError/ValueError when it cannot be had: the caller says so."""
    try:
        import tomllib                                         # here, not at the top: the system python3 (3.9) has none, and claude-login-renew.py imports this file for the vault dates alone
    except ImportError as e:                                   # `roles`/`check` on that python3: the documented exit 1 with what to do, not an uncaught traceback
        raise OSError(f"Python 3.11+ is needed to read the config (this is {sys.version.split()[0]}, it has no tomllib): run it with python3.11 or newer") from e
    seam = os.environ.get("CLAUDE_CRED_MAP_CONFIG")
    if seam:
        return tomllib.loads(Path(seam).read_text())
    gc = os.environ.get("CLAUDE_CRED_GC") or shutil.which("gc") or "gc"
    r = subprocess.run([gc, "config", "show"], capture_output=True, text=True, timeout=90, cwd=str(city_root()), check=False)
    if r.returncode != 0:
        raise OSError(f"`gc config show` exited {r.returncode}: {r.stderr.strip()[:200]}")
    return tomllib.loads(r.stdout)


def roles(cfg: dict) -> List[dict]:
    """[{role, rig, provider, credential, suspended}] sorted by credential then role. The agents the engine synthesizes from a PROVIDER (name == a provider's name) are not roles."""
    providers = cfg.get("providers") or {}
    ws = str((cfg.get("workspace") or {}).get("provider") or "claude")
    out = []
    for a in cfg.get("agent") or []:
        name = a.get("name")
        if not isinstance(name, str) or name in providers:
            continue
        out.append({"role": name, "rig": a.get("dir") or "", "provider": a.get("provider") or f"({ws}, the workspace default)",
                    "credential": kind_of(a, providers, ws), "suspended": bool(a.get("suspended"))})
    order = {FULL: 0, TOKEN: 1, DEFAULT: 2, NO_CLAUDE: 3}
    return sorted(out, key=lambda r: (order[r["credential"]], r["role"], r["rig"]))


def unpinned_live(rs: List[dict]) -> List[dict]:
    return [r for r in rs if r["credential"] == DEFAULT and not r["suspended"]]


# ── the vault: dates only ─────────────────────────────────────────────────────────────────────
def _ts(s) -> Optional[float]:
    if not isinstance(s, str) or not s.strip():
        return None
    try:
        d = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()


def vault_url() -> str:
    return os.environ.get("CLAUDE_CRED_BW_URL") or "http://127.0.0.1:18587"


def vault_tokens(timeout: float = 10.0) -> Tuple[str, Dict[str, dict]]:
    """(status, {email: {generated, source, has_token}}). status: 'ok' (an empty vault is ok: no token registered) | 'unreachable' (bw serve does not answer) | 'unreadable' (an answer with no
    shape of a list of items). An item with no readable date has generated=None: its end is unknown (has_token says whether a token is in it). The token (`notes`) is never kept."""
    q = urllib.parse.urlencode({"search": ITEM_PREFIX})
    try:
        with urllib.request.urlopen(f"{vault_url()}/list/object/items?{q}", timeout=timeout) as r:     # urlopen of a loopback URL: the host is ours, the query has no account in it
            raw = r.read()
    except (OSError, urllib.error.URLError):
        return "unreachable", {}
    try:
        body = json.loads(raw.decode())
    except (ValueError, RecursionError):                       # it answered, with something that is not JSON (an error page, a proxy): not "down", not a list either
        return "unreadable", {}
    items = ((body.get("data") or {}).get("data")) if isinstance(body, dict) and isinstance(body.get("data"), dict) else None
    if not isinstance(items, list):
        return "unreadable", {}
    out: Dict[str, dict] = {}
    for it in items:
        if not isinstance(it, dict) or not isinstance(it.get("name"), str) or not it["name"].startswith(ITEM_PREFIX) or it.get("deletedDate"):
            continue
        email = it["name"][len(ITEM_PREFIX):].strip().lower()
        if not email:
            continue
        gen, src = None, None
        for f in it.get("fields") or []:
            if isinstance(f, dict) and f.get("name") == "gerado_em" and _ts(f.get("value")) is not None:
                gen, src = _ts(f["value"]), "gerado_em"
        if gen is None:
            for key in ("revisionDate", "creationDate"):
                if _ts(it.get(key)) is not None:
                    gen, src = _ts(it[key]), key
                    break
        out[email] = {"generated": gen, "source": src, "has_token": bool(str(it.get("notes") or "").strip())}
    return "ok", out


def token_life_s() -> float:
    try:
        return float(os.environ["CLAUDE_CRED_TOKEN_LIFE_S"])
    except (KeyError, ValueError):
        return float(TOKEN_LIFE_S)


def token_state(rec: Optional[dict], t: float) -> dict:
    """{state: 'none'|'empty'|'undated'|'ok', end, left, source}. 'none' = no vault item for the account; 'empty' = the item has no token in it; 'undated' = a token with no date to count from."""
    if not rec:
        return {"state": "none", "end": None, "left": None, "source": None}
    if not rec.get("has_token"):
        return {"state": "empty", "end": None, "left": None, "source": rec.get("source")}
    if rec.get("generated") is None:
        return {"state": "undated", "end": None, "left": None, "source": None}
    end = rec["generated"] + token_life_s()
    return {"state": "ok", "end": end, "left": end - t, "source": rec.get("source")}


def level(left: Optional[float], thresholds) -> Optional[int]:
    """The TIGHTEST threshold `left` has crossed (seconds); 0 = already ended; None = not within any (or unknown): nothing to say."""
    if left is None:
        return None
    if left <= 0:
        return 0
    crossed = [x for x in thresholds if left <= x]
    return min(crossed) if crossed else None


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── cli ──────────────────────────────────────────────────────────────────────────────────────
def _roles_text(rs: List[dict]) -> str:
    why = {FULL: "FULL LOGIN (Remote Control: Mayor + named crews)", TOKEN: "1-YEAR SETUP-TOKEN (pool: inference only)",
           DEFAULT: "DEFAULT LOGIN (no provider pinned: the Mayor's login)", NO_CLAUDE: "no Claude"}
    lines = []
    for k in (FULL, TOKEN, DEFAULT, NO_CLAUDE):
        sel = [r for r in rs if r["credential"] == k]
        if not sel:
            continue
        lines.append(f"{why[k]} - {len(sel)} role(s)")
        for r in sel:
            lines.append(f"    {(r['rig'] + '/' if r['rig'] else '')}{r['role']}  [{r['provider']}]" + ("  (suspended)" if r["suspended"] else ""))
    return "\n".join(lines)


def main(argv: List[str]) -> int:
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    if len(argv) != 1 or argv[0] not in ("roles", "check", "tokens"):
        print("usage: claude-credential-map.py roles|check|tokens [--json]", file=sys.stderr)
        return 64
    if argv[0] == "tokens":
        status, items = vault_tokens()
        if status != "ok":
            print(f"the vault could not be read ({status}): no token date is known", file=sys.stderr)
            return 1
        t = time.time()
        rows = {e: {**token_state(r, t), "generated": r["generated"]} for e, r in sorted(items.items())}
        if as_json:
            print(json.dumps(rows, indent=1, sort_keys=True))
        else:
            for e, s in rows.items():
                print(f"{e}: token {s['state']}" + (f", ends {iso(s['end'])} ({s['left'] / DAY:.0f} d left; counted from {s['source']})" if s["state"] == "ok" else ""))
        return 0
    try:
        rs = roles(load_config())
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f"the resolved config could not be read ({type(e).__name__}: {str(e)[:160]})", file=sys.stderr)
        return 1
    if argv[0] == "roles":
        print(json.dumps(rs, indent=1) if as_json else _roles_text(rs))
        return 0
    bad = unpinned_live(rs)
    for r in bad:
        print(f"unpinned: {(r['rig'] + '/' if r['rig'] else '')}{r['role']} runs on the workspace default provider - the Mayor's login, not a token", file=sys.stderr)
    return 3 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
