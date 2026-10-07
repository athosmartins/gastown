#!/usr/bin/env python3
"""claude-crew-account — ga-qdtmq2 (Fase 2 da ga-xoe5ao): the Claude account of the Mayor and the named crews, LIVE.

Who this is for: the sessions launched with --remote-control (providers claude-rc / claude-rc-crew). They are NOT wrapped
(city.toml), so they read the DEFAULT Keychain item "Claude Code-credentials". claude re-reads that item every ~30 s, so
rewriting it moves every one of them to another account in about a minute, with the SAME remote session, the conversation
intact and no restart (measured, ga-2yyitx / ga-yyltfk). Decision of Athos (06/10): live, no restart.

The decision is NOT taken here. The pool daemon (claude-pool-account.py, ga-8hcnvb.1) is the single decider of "which
account is current" (CLAUDE_POOL_STATE); this script FOLLOWS it, so agents, crews and services never disagree
(incident 30/09). It never calls claude and never makes a billable call: the only network call is the account PROFILE
(who owns this token), which costs nothing.

What it does, every run (launchd StartInterval, single instance via flock):
  1. WHO HOLDS the default item now? Asked of the profile endpoint (not remembered, not read from ~/.claude.json: a
     login written by hand would make a remembered answer wrong, and writing an account's blob over another account's
     copy would destroy a login that needs a human puzzle to redo). Unknown -> change nothing.
  2. SYNC-BACK: the account that holds the default item keeps rotating its refresh token (the CLI does it, ~every 8 h).
     A refresh token lives in ONE place at a time, so the default item's blob is copied back to that account's own item
     (never over a NEWER login there), otherwise the stored copy ages and the next switch would hand out a dead login.
  3. FOLLOW: if the decision names another account, write ITS full-scope login into the default item. A setup-token (no
     refresh token / no sessions scope) is never written there: it kills Remote Control (Athos 05/10). If the wanted
     account has no usable full login, the crews STAY where they are and a named alert says exactly which login is missing;
     only when the account they are on is itself exhausted do they fall to the next account that has one.
  4. VERIFY: after a switch, every session that had a Remote Control bridge must still have one 60 s later.

Secrets: held in memory; the only place they leave is `security -i` STDIN (hex). Never argv, env, log, state or alert.
Accounts are named by e-mail + sha256[:8] fingerprints.

KNOBS: GC_CREW_ACCOUNT=0 or <city>/.gc/no-crew-account -> the run does nothing. `--dry-run` prints what it WOULD do.
SEAMS (tests): CLAUDE_CREW_STATE, CLAUDE_CREW_DECISION, CLAUDE_CREW_ACCOUNTS (json), CLAUDE_CREW_ACCOUNTS_DIR,
CLAUDE_CREW_SECURITY, CLAUDE_CREW_SESSIONS_DIR, CLAUDE_CREW_NOTIFY, CLAUDE_CREW_NOW, CLAUDE_CREW_USER,
CLAUDE_CREW_PROFILE_URL (honoured ONLY for a loopback host).
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import pwd
import re
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

DEFAULT_SERVICE = "Claude Code-credentials"          # Mayor's and the crews'. The ONLY item a switch writes.
RESERVE_PREFIX = "Claude Code-credentials-CREW-RESERVE-"
RC_SCOPE = "user:sessions:claude_code"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
DEFAULT_DECISION = "/Users/athos/shared/data/claude_pool_current_account.json"
DEFAULT_STATE = "/Users/athos/shared/data/claude_crew_current_account.json"
DRY = False                     # --dry-run: logs go to stderr, nothing is written, nothing is notified (a real push once was)
IDENTITY_TTL_S = 6 * 3600       # a token is re-asked of the profile at least this often (it also changes on every refresh)
VERIFY_AFTER_S = 60             # the CLI re-reads the item every ~30 s; the bridge is checked this long after a switch
VERIFY_GIVE_UP_S = 900
MIN_REFRESH_LEFT_S = 86400      # a login whose refresh token has < 1 day left is not a source
ALERT_EVERY_S = 6 * 3600
USER_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,63}")
SERVICE_RE = re.compile(r"Claude Code-credentials[A-Za-z0-9 ._@-]{0,120}")
POOL_CRED_DIR = str(Path.home() / ".gastown" / "claude-pool-cred")

# account -> where its FULL-SCOPE login lives when it is not the active one. "dir" = a CLAUDE_CONFIG_DIR under
# ~/.gastown/claude-accounts (item = "Claude Code-credentials-" + sha256(ABSOLUTE PATH)[:8]; DERIVE it, never copy a hash
# from a note: the 05/10 note had two swapped). "item" = a fixed service name. terrenos has no login of its own any more:
# its home WAS the default item.
DEFAULT_ACCOUNTS: Dict[str, dict] = {
    "athoscrypto@gmail.com": {"dir": "athoscrypto"},
    "throw.away.amb@gmail.com": {"dir": "throw.away.amb"},
    "athosb85@gmail.com": {"dir": "athosb85"},
    "terrenos.incorporacoes@gmail.com": {"dir": "terrenos"},
    "athosmartins@gmail.com": {"item": "Claude Code-credentials-BACKUP-athosmartins-20261004"},
}


# ── config / clock / log ──────────────────────────────────────────────
def now() -> float:
    v = os.environ.get("CLAUDE_CREW_NOW", "")
    try:
        f = float(v) if v else None
    except ValueError:
        f = None
    return f if f is not None and f > 1e9 else time.time()


def _iso(ts: float) -> str:
    try:
        return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return "unknown-time"


def city() -> Optional[Path]:
    c = os.environ.get("GC_CITY_PATH", "")
    return Path(c) if c else None


def log(level: str, msg: str) -> None:
    if "sk-ant-" in msg:
        msg = "[line withheld: token-shaped text]"
    line = f"{_iso(now())} pid={os.getpid()} crew {level} {msg}"
    c = None if DRY else city()
    try:
        if c and (c / ".gc" / "logs").is_dir():
            with open(c / ".gc" / "logs" / "claude-crew-account.log", "a") as f:
                f.write(line + "\n")
            return
    except OSError:
        pass
    print(line, file=sys.stderr)


def fp(secret) -> Optional[str]:
    return hashlib.sha256(secret.encode()).hexdigest()[:8] if isinstance(secret, str) and secret else None


def login_name() -> str:
    u = os.environ.get("CLAUDE_CREW_USER") or os.environ.get("USER", "")
    if u:
        return u
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError):
        return ""


def decision_path() -> Path:
    return Path(os.environ.get("CLAUDE_CREW_DECISION") or DEFAULT_DECISION)


def state_path() -> Path:
    return Path(os.environ.get("CLAUDE_CREW_STATE") or DEFAULT_STATE)


def sessions_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CREW_SESSIONS_DIR") or Path.home() / ".claude" / "sessions")


def security_bin() -> str:
    return os.environ.get("CLAUDE_CREW_SECURITY") or "security"


def accounts() -> Dict[str, dict]:
    raw = os.environ.get("CLAUDE_CREW_ACCOUNTS")
    if raw:
        try:
            d = json.loads(raw)
            if isinstance(d, dict):
                return d
        except ValueError:
            pass
        log("WARN", "CLAUDE_CREW_ACCOUNTS is not a json object - ignored")
    return DEFAULT_ACCOUNTS


def accounts_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CREW_ACCOUNTS_DIR") or Path.home() / ".gastown" / "claude-accounts")


def dir_service(path: str) -> str:
    """claude's item name for a config dir: the hash of the ABSOLUTE path exactly as CLAUDE_CONFIG_DIR carries it."""
    return "Claude Code-credentials-" + hashlib.sha256(os.path.abspath(os.path.expanduser(path)).encode()).hexdigest()[:8]


def reserve_service(email: str) -> str:
    return RESERVE_PREFIX + re.sub(r"[^A-Za-z0-9.@-]", "_", email)


def source_services(email: str) -> List[str]:
    """Where `email`'s login can live when it is not on the default item: its own item first, the reserve second."""
    cfg = accounts().get(email) or {}
    out: List[str] = []
    if cfg.get("item"):
        out.append(str(cfg["item"]))
    if cfg.get("dir"):
        p = Path(str(cfg["dir"]))
        out.append(dir_service(str(p if p.is_absolute() else accounts_dir() / p)))
    out.append(reserve_service(email))
    return out


def writable_services() -> set:
    """The allowlist of what this script may ever write. Anything else - the pool's item above all - is refused."""
    s = {DEFAULT_SERVICE}
    for e in accounts():
        s.update(source_services(e))
    s.discard("Claude Code-credentials-" + hashlib.sha256(POOL_CRED_DIR.encode()).hexdigest()[:8])
    return s


# ── Keychain (secret only on STDIN) ─────────────────────────────────────
def _sec(*args: str, stdin: Optional[str] = None):
    return subprocess.run([security_bin(), *args], input=stdin, capture_output=True, text=True, timeout=20, check=False)


def kc_read(service: str) -> Tuple[str, Optional[str], Optional[dict]]:
    """('ok', acct, blob) | ('missing', None, None) | ('unknown', None, None). Only exit 44 is 'not there': a locked
    keychain or a crashed `security` is 'could not tell', and 'could not tell' never triggers a write."""
    try:
        r = _sec("find-generic-password", "-s", service)
        if r.returncode == 44:
            return "missing", None, None
        if r.returncode != 0:
            return "unknown", None, None
        m = re.search(r'"acct"<blob>="([^"]*)"', r.stdout)
        acct = m.group(1) if m else ""
        if not USER_RE.fullmatch(acct):
            return "unknown", None, None
        r2 = _sec("find-generic-password", "-a", acct, "-s", service, "-w")
    except (OSError, subprocess.SubprocessError):
        return "unknown", None, None
    if r2.returncode == 44:
        return "missing", None, None
    if r2.returncode != 0:
        return "unknown", None, None
    try:
        blob = json.loads(r2.stdout.strip())
    except ValueError:
        return "unknown", None, None
    if not isinstance(blob, dict) or not isinstance(blob.get("claudeAiOauth"), dict):
        return "unknown", None, None
    return "ok", acct, blob


def kc_write(service: str, acct: str, blob: dict) -> bool:
    """Rewrite ONE allowlisted item. The secret travels only as hex on `security -i`'s stdin."""
    if service not in writable_services() or not SERVICE_RE.fullmatch(service) or '"' in service:
        log("ERROR", "refusing to write a Keychain item that is not on this script's allowlist")
        return False
    if not USER_RE.fullmatch(acct or ""):
        log("ERROR", "refusing to build a security command for an account name that is not a plain login name")
        return False
    cmd = f'add-generic-password -U -a "{acct}" -s "{service}" -X {json.dumps(blob).encode().hex()}\n'
    try:
        r = _sec("-i", stdin=cmd)
    except (OSError, subprocess.SubprocessError) as e:
        log("ERROR", f"security -i failed to run ({type(e).__name__})")
        return False
    if r.returncode != 0:
        log("ERROR", f"security -i exit={r.returncode}")
        return False
    return True


def same_login(a: dict, b: dict) -> bool:
    oa, ob = a.get("claudeAiOauth", {}), b.get("claudeAiOauth", {})
    return fp(oa.get("accessToken")) == fp(ob.get("accessToken")) and fp(oa.get("refreshToken")) == fp(ob.get("refreshToken"))


def verified_write(service: str, acct: str, blob: dict) -> bool:
    if not kc_write(service, acct, blob):
        return False
    s, _, back = kc_read(service)
    return s == "ok" and back is not None and same_login(back, blob)


# ── a login: usable? whose? ───────────────────────────────────────────────
def _ms_left(o: dict, key: str, t: float) -> Optional[float]:
    v = o.get(key)
    return v / 1000.0 - t if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def full_login(blob: Optional[dict], t: float) -> Tuple[bool, str]:
    """A login Remote Control accepts: a sessions scope and a refresh token that is still alive. A setup-token is not one."""
    o = (blob or {}).get("claudeAiOauth") or {}
    if not isinstance(o.get("accessToken"), str) or not o["accessToken"]:
        return False, "no access token"
    if not isinstance(o.get("refreshToken"), str) or not o["refreshToken"]:
        return False, "no refresh token (a setup-token: it would kill Remote Control)"
    if RC_SCOPE not in (o.get("scopes") or []):
        return False, f"scope {RC_SCOPE} missing"
    left = _ms_left(o, "refreshTokenExpiresAt", t)
    if left is not None and left < MIN_REFRESH_LEFT_S:
        return False, "refresh token expires within a day (the login has to be redone)"
    return True, "ok"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp_, code, msg, headers, newurl):
        return None


def profile_url() -> str:
    u = os.environ.get("CLAUDE_CREW_PROFILE_URL", "")
    if u:
        if (urllib.parse.urlparse(u).hostname or "") in ("127.0.0.1", "localhost", "::1"):
            return u
        log("WARN", "ignoring CLAUDE_CREW_PROFILE_URL: only loopback is honoured (the Bearer must not be aimed elsewhere)")
    return PROFILE_URL


def profile_email(access: str) -> Optional[str]:
    """Whose token this is. None = could not tell (expired token, network, 5xx, anything but a 200 with an e-mail)."""
    req = urllib.request.Request(profile_url(), headers={"Authorization": "Bearer " + access,
                                 "anthropic-beta": "oauth-2025-04-20", "user-agent": "claude-crew-account/1"})
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=10) as r:
            body = json.loads(r.read().decode())
        e = (body.get("account") or {}).get("email")
        return e.strip().lower() if isinstance(e, str) and "@" in e else None
    except Exception:  # noqa: BLE001 - could not tell is a legitimate answer
        return None


def identity(st: dict, blob: dict, t: float) -> Optional[str]:
    o = blob["claudeAiOauth"]
    f = fp(o.get("accessToken"))
    c = st.get("identity")
    if isinstance(c, dict) and c.get("fp") == f and (c.get("via") == "switch" or t - float(c.get("at", 0)) < IDENTITY_TTL_S):
        return c.get("email")
    e = profile_email(o["accessToken"]) if f else None
    if e:
        st["identity"] = {"fp": f, "email": e, "at": t, "via": "profile"}
    return e


# ── state / alerts ───────────────────────────────────────────────────────
def load_json(p: Path) -> Optional[dict]:
    try:
        d = json.loads(p.read_bytes().decode())
    except (OSError, ValueError, RecursionError):
        return None
    return d if isinstance(d, dict) else None


def publish_state(st: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    st["schema"], st["updated"] = 1, _iso(now())
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(st, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, p)


def alert(st: dict, key: str, msg: str, t: float) -> None:
    """One named line in the log, and ONE push per key per ALERT_EVERY_S. The text carries 'job falhou' so notify routes it
    to the auto-repair path (bead + agent) and not to a mute digest (CLAUDE.md, 'Job agendado novo')."""
    log("WARN", ("DRY-RUN would alert: " if DRY else "") + msg)
    if DRY:
        return                                             # a dry run never pushes and never records an alert as sent
    al = st.setdefault("alerts", {})
    if t - float(al.get(key, 0)) < ALERT_EVERY_S:
        return
    al[key] = t
    n = os.environ.get("CLAUDE_CREW_NOTIFY") or shutil.which("notify")
    if not n:
        return
    try:
        subprocess.run([n, "-t", "Troca de conta (crews)", "-p", "4", f"job falhou: claude-crew-account — {msg}"],
                       capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


# ── Remote Control bridges ────────────────────────────────────────────────
def bridges() -> Dict[int, str]:
    """{pid: bridgeSessionId} of the live sessions that HAVE a Remote Control bridge."""
    out: Dict[int, str] = {}
    try:
        files = list(sessions_dir().glob("*.json"))
    except OSError:
        return out
    for f in files:
        d = load_json(f)
        if not d or not d.get("bridgeSessionId"):
            continue
        try:
            pid = int(d.get("pid") or f.stem)
            os.kill(pid, 0)
        except (ValueError, OSError):
            continue
        out[pid] = str(d["bridgeSessionId"])
    return out


def check_bridges(st: dict, t: float) -> None:
    pv = st.get("pending_verify")
    if not isinstance(pv, dict) or t - float(pv.get("since", 0)) < VERIFY_AFTER_S:
        return
    now_b, lost = bridges(), []
    for pid_s in pv.get("pids", {}):
        pid = int(pid_s)
        try:
            os.kill(pid, 0)
        except OSError:
            continue                       # the session ended on its own: not a switch casualty
        if pid not in now_b:
            lost.append(pid)
    if lost:
        alert(st, "rc-lost", f"after the switch to {pv.get('to')} the sessions {sorted(lost)} lost Remote Control "
              "(restart them at an idle moment)", t)
        st["rc_lost"] = {"pids": sorted(lost), "at": t, "to": pv.get("to")}
    else:
        log("INFO", f"switch to {pv.get('to')}: all {len(pv.get('pids', {}))} Remote Control bridges are still up")
        st.pop("rc_lost", None)
    st.pop("pending_verify", None)


# ── the run ─────────────────────────────────────────────────────────────
def disabled() -> Optional[str]:
    if os.environ.get("GC_CREW_ACCOUNT") == "0":
        return "GC_CREW_ACCOUNT=0"
    c = city()
    if c and (c / ".gc" / "no-crew-account").exists():
        return str(c / ".gc" / "no-crew-account")
    return None


def exhausted(dec: dict, email: str, t: float) -> bool:
    v = (dec.get("exhausted") or {}).get(email)
    r = v.get("reset_epoch") if isinstance(v, dict) else None
    return isinstance(r, (int, float)) and r > t


def load_source(email: str, t: float) -> Tuple[Optional[Tuple[str, str, dict]], List[str]]:
    """The first usable full login of `email`: ((service, acct, blob), []) or (None, [why-not per place])."""
    why = []
    for svc in source_services(email):
        s, acct, blob = kc_read(svc)
        if s != "ok":
            why.append(f"{svc}: {s}")
            continue
        ok, reason = full_login(blob, t)
        if ok:
            return (svc, acct, blob), []      # type: ignore[return-value]
        why.append(f"{svc}: {reason}")
    return None, why


def sync_back(st: dict, ident: str, cur: dict, t: float, dry: bool) -> None:
    """Copy the default item's (rotated) login back to its owner's own item - never over a NEWER login there. An account
    with no item of its own gets a RESERVE item, so the login it holds is never lost when the default item is overwritten."""
    ok, _ = full_login(cur, t)
    if not ok:
        return
    o = cur["claudeAiOauth"]
    dest: Optional[Tuple[str, str]] = None
    for svc in source_services(ident):                          # its own item(s) first, the reserve last
        s, acct, src = kc_read(svc)
        if s == "unknown":
            return                                              # could not tell: never write on a guess
        if s != "ok":
            continue
        so = src["claudeAiOauth"]
        if fp(so.get("refreshToken")) == fp(o.get("refreshToken")):
            return                                              # already the same login
        if (_ms_left(so, "refreshTokenExpiresAt", t) or 0) > (_ms_left(o, "refreshTokenExpiresAt", t) or 0):
            log("INFO", f"sync-back to {svc} skipped: the stored login is a NEWER one")
            return
        dest = (svc, acct or login_name())
        break
    if dest is None:
        dest = (reserve_service(ident), login_name())
    if dry:
        log("INFO", f"DRY-RUN would sync {ident} back to {dest[0]}")
        return
    if verified_write(dest[0], dest[1], cur):
        log("INFO", f"sync-back: {ident} login copied to {dest[0]} (fp refresh {fp(o.get('refreshToken'))})")
    else:
        log("ERROR", f"sync-back to {dest[0]} could not be verified")


def choose(st: dict, dec: dict, ident: str, t: float) -> Tuple[Optional[str], Optional[Tuple[str, str, dict]], str]:
    """(email, source, reason): who the crews should be on and where its login is. email None = stay where they are."""
    want = str(dec.get("current") or "").strip().lower()
    if want == ident or not want:
        return None, None, "in sync"
    src, why = load_source(want, t)
    if src:
        return want, src, "follow the pool decision"
    msg = f"the pool is on {want} but there is no usable full login for it ({'; '.join(why)}) - the crews stay on {ident}"
    if not exhausted(dec, ident, t):
        alert(st, f"no-login:{want}", msg + ". Fix: log {0} in (claude auth login with its CLAUDE_CONFIG_DIR) - a human step".format(want), t)
        return None, None, "wanted account has no full login; current one still has balance"
    for other in accounts():
        if other in (ident, want) or exhausted(dec, other, t):
            continue
        src, _ = load_source(other, t)
        if src:
            alert(st, f"fallback:{other}", f"{ident} is exhausted and the pool's {want} has no full login: crews fall to {other}", t)
            return other, src, "fallback"
    alert(st, "stuck", msg + " and no other account has a usable full login: the crews are STUCK", t)
    return None, None, "stuck"


def run_once(dry: bool = False) -> int:
    global DRY
    DRY = dry                                                  # log()/alert() honor it by construction, not by the caller remembering
    off = disabled()
    if off:
        return 0
    user, t = login_name(), now()
    if not USER_RE.fullmatch(user):
        log("ERROR", "no plain login name - refusing to act")
        return 0
    dec = load_json(decision_path())
    if not dec or not isinstance(dec.get("current"), str):
        log("WARN", "no pool decision to follow yet - the crews stay")
        return 0
    st = load_json(state_path()) or {}
    # NB: no "is the decision fresh?" gate. `updated` in the pool's file moves only when the pool CHANGES account (measured
    # 06/10: 75 min old while the daemon ran every minute), so age says nothing about whether the daemon is alive. Following
    # an old-but-unchanged decision is correct (the crews are already on it); the pool daemon's liveness is ga-8hcnvb.3's.
    s, acct, cur = kc_read(DEFAULT_SERVICE)
    if s != "ok":
        log("WARN", f"the default item is {s} - nothing to do")
        return 0
    ok, why = full_login(cur, t)
    ident = identity(st, cur, t)
    want = dec["current"].strip().lower()
    st.update({"target": want, "default_fp": fp(cur["claudeAiOauth"].get("accessToken"))})
    if ident is None:
        if ok:
            log("WARN", "cannot tell whose login the default item holds (profile unanswered) - not touching it")
            if not dry:
                publish_state(st)
            return 0
        alert(st, "default-not-full", f"the default item holds no full login ({why}): Remote Control is broken for Mayor and crews", t)
        target, src, reason = want, load_source(want, t)[0], "heal"
        if not src:
            if not dry:
                publish_state(st)
            return 0
        ident = "(unknown)"
    else:
        st["current"] = ident
        sync_back(st, ident, cur, t, dry)
        target, src, reason = choose(st, dec, ident, t)
    if target is None or src is None:
        check_bridges(st, t)
        if not dry:
            publish_state(st)
        return 0
    svc, sacct, blob = src
    claimed = profile_email(blob["claudeAiOauth"]["accessToken"])
    if claimed is not None and claimed != target:
        alert(st, f"wrong-owner:{target}", f"the item {svc} belongs to {claimed}, not {target} - NOT using it", t)
        if not dry:
            publish_state(st)
        return 0
    if dry:
        log("INFO", f"DRY-RUN would switch the crews {ident} -> {target} ({reason}) from {svc}")
        return 0
    before = bridges()
    if not verified_write(DEFAULT_SERVICE, acct or user, blob):
        alert(st, "write-failed", f"could not write the {target} login to the default item (verify failed)", t)
        publish_state(st)
        return 0
    st["identity"] = {"fp": fp(blob["claudeAiOauth"].get("accessToken")), "email": target, "at": t, "via": "switch"}
    st["current"] = target
    st["last_switch"] = {"from": ident, "to": target, "reason": reason, "at": t, "source": svc}
    st["pending_verify"] = {"since": t, "to": target, "pids": {str(p): b for p, b in before.items()}}
    st.setdefault("alerts", {}).pop("rc-lost", None)
    log("INFO", f"SWITCH crews {ident} -> {target} ({reason}); fp access {st['identity']['fp']}; "
                f"{len(before)} Remote Control bridges to verify")
    publish_state(st)
    return 0


def main(argv: List[str]) -> int:
    global DRY
    dry = DRY = "--dry-run" in argv
    lock = (city() / ".gc" / "claude-crew-account.lock") if city() and (city() / ".gc").is_dir() else state_path().with_suffix(".lock")
    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as e:
        log("ERROR", f"cannot open the lock ({type(e).__name__})")
        return 0
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0                                           # another run is on it
    try:
        return run_once(dry)
    except Exception as e:  # noqa: BLE001 - a launchd job that crashes silently is the failure this exists to remove
        log("ERROR", f"run failed ({type(e).__name__}: {str(e)[:120]})")
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
