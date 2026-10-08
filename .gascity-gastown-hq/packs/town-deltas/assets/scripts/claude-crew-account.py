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
     copy would destroy a login that needs a human puzzle to redo). Unknown -> change nothing (the one exception: a default
     item that is not a full login is healed, whoever holds it - Remote Control is broken either way).
  2. SYNC-BACK: the account that holds the default item keeps rotating its refresh token (the CLI does it, ~every 8 h).
     A refresh token lives in ONE place at a time, so the default item's login is copied back to that account's own item
     (never over a NEWER login there), otherwise the stored copy ages and the next switch would hand out a dead login.
     It has THREE outcomes (synced / nothing to sync / could not tell or failed) and the third one is a veto: when the
     login being left could not be saved, the default item is NOT overwritten (it may hold the only valid copy of the
     rotated refresh token) and a named alert says so. Only the claudeAiOauth part moves; the rest of a blob (mcpOAuth)
     stays where it is.
  3. FOLLOW: if the decision names another account, write ITS full-scope login into the default item. A setup-token (no
     refresh token / no sessions scope) is never written there: it kills Remote Control (Athos 05/10). If the wanted
     account has no usable full login, the crews STAY where they are and a named alert says exactly which login is missing;
     only when the account they are on is itself exhausted do they fall to the next account that has one. A login that
     COULD NOT BE READ is "cannot tell", not "has none": the crews stay (exhausted or not) and `unreadable:<account>` says so.
     WHOSE login is being written is asked of the profile when it can answer. A stored copy's access token is expired for
     a day or more, so in production it usually cannot: the switch then goes ahead (fail-open, by decision - the
     alternative is crews that never move) but it is LOGGED as "owner unverified", COUNTED, remembered as unverified (the
     normal identity TTL applies), and checked as soon as the CLI has refreshed the token: a wrong owner is alerted and
     its source quarantined so it is never written again.
  4. VERIFY: after a switch, every session that had a Remote Control bridge must still have one 60 s later. A check that
     cannot be made (sessions dir unreadable, window missed) says so; it never reports success. Three verdicts, not two: up,
     LOST (push), and NOT VERIFIED - a running session whose session file exists but could not be read is neither (log +
     `rc_unjudged.unverified`, no push). A second switch before the first check is judged carries the first check along
     (judged together, 60 s after the last switch); an undelivered `rc-lost` push is retried (`rc_lost.push_pending`).

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
VERIFY_GIVE_UP_S = 900          # a check (bridges, owner) made later than this after the switch is not blamed on the switch
MIN_REFRESH_LEFT_S = 86400      # a login whose refresh token has < 1 day left is not a source
ALERT_EVERY_S = 6 * 3600
ALERT_RETRY_S = 300             # a push that was NOT delivered is retried after this, not after ALERT_EVERY_S
# measured 07/10: `security -i` cuts a stdin line at 4096 bytes and runs the remainder as a second command (a truncated
# secret would be stored). The hex doubles the blob, so a command longer than this is refused, never sent.
SECURITY_I_LINE_MAX = 4000
SB_DONE, SB_NOTHING, SB_UNSAFE = "synced", "nothing-to-sync", "could-not-sync"
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


def _num(v, default: float = 0.0) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _int(v) -> Optional[int]:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


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
    if len(cmd) - 1 > SECURITY_I_LINE_MAX:
        log("ERROR", f"refusing to write {service}: the command ({len(cmd) - 1} bytes) would be cut by `security -i` "
                     f"(stdin lines are split at 4096) - nothing was sent")
        return False
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


def with_login(base: Optional[dict], login: dict) -> dict:
    """`base` with ONLY its claudeAiOauth taken from `login`. Whatever else the item carries (mcpOAuth: the machine's MCP
    logins) stays; and another account's extra keys never ride along."""
    out = dict(base) if isinstance(base, dict) else {}
    out["claudeAiOauth"] = login["claudeAiOauth"]
    return out


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
    """Whose login the default item holds. A profile answer is cached for IDENTITY_TTL_S. What a switch only CLAIMED
    ("switch-unverified") is never taken as an answer: the profile is asked again every run, and the claim is used only
    as the fallback while it is the same token and inside the TTL."""
    o = blob["claudeAiOauth"]
    f = fp(o.get("accessToken"))
    c = st.get("identity")
    fresh = isinstance(c, dict) and c.get("fp") == f and t - _num(c.get("at")) < IDENTITY_TTL_S
    if fresh and c.get("via") == "profile":
        return c.get("email")
    e = profile_email(o["accessToken"]) if f else None
    if e:
        st["identity"] = {"fp": f, "email": e, "at": t, "via": "profile"}
        return e
    return c.get("email") if fresh else None


# ── state / alerts ───────────────────────────────────────────────────────
def load_json(p: Path) -> Optional[dict]:
    try:
        d = json.loads(p.read_bytes().decode())
    except (OSError, ValueError, RecursionError):
        return None
    return d if isinstance(d, dict) else None


def load_state() -> Tuple[dict, str]:
    """(state, 'ok'|'missing'|'unreadable'|'corrupt'). A missing file is the first run; the other two are said out loud."""
    try:
        raw = state_path().read_bytes()
    except FileNotFoundError:
        return {}, "missing"
    except OSError:
        return {}, "unreadable"
    try:
        d = json.loads(raw.decode())
    except (ValueError, RecursionError):
        return {}, "corrupt"
    return (d, "ok") if isinstance(d, dict) else ({}, "corrupt")


def publish_state(st: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    st["schema"], st["updated"] = 1, _iso(now())
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(st, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, p)


def alert(st: dict, key: str, msg: str, t: float) -> bool:
    """One named line in the log, and ONE push per key per ALERT_EVERY_S. The text carries 'job falhou' so notify routes it
    to the auto-repair path (bead + agent) and not to a mute digest (CLAUDE.md, 'Job agendado novo').
    Returns True only when THIS call delivered the push: a condition that fires once (rc-lost) keeps the False and retries."""
    log("WARN", ("DRY-RUN would alert: " if DRY else "") + msg)
    if DRY:
        return False                                       # a dry run never pushes and never records an alert as sent
    al = st.setdefault("alerts", {})
    if t - _num(al.get(key)) < ALERT_EVERY_S:
        return False
    n = os.environ.get("CLAUDE_CREW_NOTIFY") or shutil.which("notify")
    delivered = False
    if not n:
        log("ERROR", f"no notify binary: the push '{key}' could not be sent")
    else:
        try:
            r = subprocess.run([n, "-t", "Troca de conta (crews)", "-p", "4", f"job falhou: claude-crew-account — {msg}"],
                               capture_output=True, text=True, timeout=30, check=False)
            delivered = r.returncode == 0
            if not delivered:
                log("ERROR", f"notify exit={r.returncode}: the push '{key}' was not delivered")
        except (OSError, subprocess.SubprocessError) as e:
            log("ERROR", f"notify could not run ({type(e).__name__}): the push '{key}' was not delivered")
    # "told" only when it was delivered; otherwise the key is set so that it is retried after ALERT_RETRY_S
    al[key] = t if delivered else t - ALERT_EVERY_S + ALERT_RETRY_S
    return delivered


# ── Remote Control bridges ────────────────────────────────────────────────
def proc_start(pid: int) -> Optional[str]:
    """`ps lstart` of a pid in UTC (the format of ~/.claude/sessions/*.json `procStart`), whitespace-normalized.
    '' = no such process; None = could not ask."""
    try:
        r = subprocess.run(["/bin/ps" if os.path.exists("/bin/ps") else "ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=5, check=False,
                           env={**os.environ, "TZ": "UTC", "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return ""                                          # rc 1 and not a word on either stream: that is how ps says "no such process"
    if r.returncode != 0:
        return None                                        # it complained (bad or too-large pid ...) or failed: "could not ask"
    return " ".join(r.stdout.split())


def alive(pid: int, start: Optional[str] = None) -> bool:
    """Is `pid` still THE session that was recorded? A bare kill(pid, 0) says yes to a pid the OS has since handed to a
    stranger; the start time recorded in the session file tells them apart."""
    if pid <= 0:
        return False                                       # kill(0, 0) / kill(-1, 0) signal a whole group and "succeed": not a process
    if start:
        ps = proc_start(pid)
        if ps is not None:
            return ps == " ".join(str(start).split())
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True                                        # it exists, it is just not ours to signal
    except OSError:
        return False
    return True


def scan_sessions() -> Optional[Tuple[Dict[int, dict], List[str]]]:
    """({pid: {bridge, start}} of the live sessions that HAVE a Remote Control bridge, [names of the session files that exist
    but could not be read]). None = the sessions dir could not be read: that is not 'no bridges' and must never be reported
    as success. The second list is the third state: a session behind one of those files is neither 'has a bridge' nor 'lost'."""
    d = sessions_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    out: Dict[int, dict] = {}
    unread: List[str] = []
    for n in names:
        if not n.endswith(".json"):
            continue
        data = load_json(d / n)
        if data is None:
            if (d / n).exists():                           # it is there but cannot be read: not the same as "no bridge"
                unread.append(n)
            continue                                       # (a file that vanished is a session that ended: not a problem)
        if not data.get("bridgeSessionId"):
            continue
        pid = _int(data.get("pid") or n[:-5])
        start = data.get("procStart") if isinstance(data.get("procStart"), str) else ""
        if pid is None or not alive(pid, start):
            continue
        out[pid] = {"bridge": str(data["bridgeSessionId"]), "start": start}
    if unread:
        log("WARN", f"{len(unread)} session file(s) could not be read ({', '.join(unread[:5])}"
                    f"{', ...' if len(unread) > 5 else ''}) - a Remote Control bridge in them is NOT counted")
    return out, unread


def bridges() -> Optional[Dict[int, dict]]:
    """The first half of scan_sessions(): who has a bridge now. None = the sessions dir could not be read."""
    s = scan_sessions()
    return None if s is None else s[0]


def carry_check(old: dict, new: dict) -> dict:
    """A second switch while the first one's check is still pending: the first check is not dropped. The second list of
    bridges is taken AFTER the first switch, so a session the first switch cost is already missing from it - the first list
    rides along (union) and everything is judged together, 60 s after the LAST switch. A record that cannot be read, or a
    first list that was blind, keeps the check blind: 'cannot tell' is said, never 'nothing to verify'."""
    op, ost = old.get("pids"), old.get("starts") or {}
    if not isinstance(op, dict) or not isinstance(ost, dict):
        op, ost, new["blind"] = {}, {}, True
    new["pids"] = {**op, **new["pids"]}
    new["starts"] = {**ost, **new["starts"]}
    new["blind"] = bool(old.get("blind")) or new["blind"]
    return new


def check_bridges(st: dict, t: float) -> bool:
    """Judge the pending post-switch check. Returns True when it changed `st`."""
    pv = st.get("pending_verify")
    if not isinstance(pv, dict):
        return False
    to, age = pv.get("to"), t - _num(pv.get("since"))
    if age < VERIFY_AFTER_S:
        return False
    if age > VERIFY_GIVE_UP_S:
        log("WARN", f"switch to {to}: the Remote Control check came too late ({int(age)} s after the switch, window "
                    f"{VERIFY_GIVE_UP_S} s) - not judged, and not blamed on the switch")
        st["rc_unjudged"] = {"at": t, "to": to, "age_s": int(age)}
        st.pop("pending_verify", None)
        return True
    scan = scan_sessions()
    if scan is None:
        if not pv.get("unreadable"):
            log("WARN", f"switch to {to}: could not read the sessions dir - Remote Control NOT verified yet (will retry)")
            pv["unreadable"] = t
            return True
        return False
    if pv.get("blind"):
        log("WARN", f"switch to {to}: the sessions dir was unreadable when the crews switched, so there is no list of bridges "
                    "to compare - Remote Control NOT verified")
        st["rc_unjudged"] = {"at": t, "to": to, "blind": True}
        st.pop("pending_verify", None)
        return True
    now_b, unread = scan
    before = pv.get("pids") or {}
    starts = pv.get("starts") or {}
    # a session file we could not read may be where a running session's bridge went: its absence from `now_b` is then
    # "cannot tell", not "lost". Files are named <pid>.json; one we cannot tie to a pid could be anybody's.
    unread_pids = {_int(n[:-5]) for n in unread}
    lost, unverified, up, ended = [], [], 0, 0
    for pid_s in before:
        pid = _int(pid_s)
        if pid is None or not alive(pid, starts.get(pid_s)):
            ended += 1                     # the session ended on its own: not a switch casualty, and not a bridge that is up
        elif pid in now_b:
            up += 1
        elif None in unread_pids or pid in unread_pids:
            unverified.append(pid)
        else:
            lost.append(pid)
    if unverified:
        log("WARN", f"switch to {to}: the sessions {sorted(unverified)} are running but their session file could not be read - "
                    f"Remote Control NOT verified for them (not counted as lost, not counted as up; {up} of {len(before)} "
                    "bridges confirmed up)")
        st["rc_unjudged"] = {"at": t, "to": to, "unverified": sorted(unverified)}
    if lost:
        told = alert(st, "rc-lost", rc_lost_msg(to, lost), t)
        st["rc_lost"] = {"pids": sorted(lost), "at": t, "to": to, "push_pending": not told}
    else:
        st.pop("rc_lost", None)
        if unverified:
            pass                           # said above: neither "all up" nor "none left" may follow
        elif not before:
            log("INFO", f"switch to {to}: no Remote Control bridge existed at the switch - nothing to verify")
        elif not up:
            log("INFO", f"switch to {to}: none of the {len(before)} sessions that had a Remote Control bridge is still running "
                        "(they ended on their own) - no session was left to verify")
        elif ended:
            log("INFO", f"switch to {to}: {up} of {len(before)} Remote Control bridges are still up; {ended} session(s) ended on "
                        "their own before the check (not a switch casualty, not verified)")
        else:
            log("INFO", f"switch to {to}: all {len(before)} Remote Control bridges are still up")
    st.pop("pending_verify", None)
    return True


def rc_lost_msg(to, pids) -> str:
    return f"after the switch to {to} the sessions {sorted(pids)} lost Remote Control (restart them at an idle moment)"


def retry_rc_lost_push(st: dict, t: float) -> None:
    """The rc-lost condition fires ONCE (the check is popped as soon as it is judged), so nothing else would ever call
    alert() for it again: a push that was not delivered is retried here, after ALERT_RETRY_S, until it is told - and then
    never again (a delivered push is not repeated for the same switch)."""
    rl = st.get("rc_lost")
    if DRY or not isinstance(rl, dict) or not rl.get("push_pending"):
        return
    if t - _num(st.get("alerts", {}).get("rc-lost")) < ALERT_EVERY_S:
        return                                             # inside the retry window: alert() would only repeat the log line
    if alert(st, "rc-lost", rc_lost_msg(rl.get("to"), rl.get("pids") or []), t):
        rl["push_pending"] = False


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


def load_source(email: str, t: float, st: Optional[dict] = None) -> Tuple[Optional[Tuple[str, str, dict]], List[str], bool]:
    """The first usable full login of `email`: ((service, acct, blob), [], False) or (None, [why-not per place], unreadable).
    'Could not read' ends the search (falling through to a later place would hand out whatever stale copy lives there) and
    sets `unreadable`: that is "cannot tell if it has a login", which no caller may treat as "it has none"."""
    why = []
    bad = (st or {}).get("bad_sources") or {}
    for svc in source_services(email):
        s, acct, blob = kc_read(svc)
        if s == "unknown":
            why.append(f"{svc}: could not be read")
            return None, why, True
        if s != "ok":
            why.append(f"{svc}: {s}")
            continue
        q = bad.get(svc)
        if isinstance(q, dict) and q.get("rfp") == fp(blob["claudeAiOauth"].get("refreshToken")):
            why.append(f"{svc}: quarantined (it turned out to hold {q.get('owner')}'s login, not {email}'s)")
            continue
        ok, reason = full_login(blob, t)
        if ok:
            return (svc, acct, blob), [], False      # type: ignore[return-value]
        why.append(f"{svc}: {reason}")
    return None, why, False


def sync_back(st: dict, ident: str, cur: dict, t: float, dry: bool) -> Tuple[str, str]:
    """Copy the default item's (rotated) login back to its owner's own item - never over a NEWER login there. An account
    with no item of its own gets a RESERVE item, so the login it holds is never lost when the default item is overwritten.
    Returns (state, detail): SB_DONE | SB_NOTHING (nothing needed saving) | SB_UNSAFE (it could not be saved, or could not
    be told: the caller must NOT overwrite the default item)."""
    ok, _ = full_login(cur, t)
    if not ok:
        return SB_NOTHING, "the default item holds no full login"
    if (st.get("identity") or {}).get("via") != "profile":
        # the owner is only CLAIMED. The login in the default item is exactly what this script wrote (same access token,
        # or the identity would have been re-asked), so there is nothing rotated to save - and writing it to the CLAIMED
        # owner's item would be the very mistake the unverified state exists to catch.
        return SB_NOTHING, "the owner is unverified and the default item is unchanged since the switch"
    o = cur["claudeAiOauth"]
    dest: Optional[Tuple[str, str, Optional[dict]]] = None
    for svc in source_services(ident):                          # its own item(s) first, the reserve last
        s, acct, src = kc_read(svc)
        if s == "unknown":
            log("WARN", f"sync-back of {ident}: {svc} could not be read - cannot tell what is stored there")
            return SB_UNSAFE, f"{svc} could not be read"
        if s != "ok":
            continue
        so = src["claudeAiOauth"]
        if fp(so.get("refreshToken")) == fp(o.get("refreshToken")):
            return SB_NOTHING, "the stored copy is already the same login"
        if not full_login(src, t)[0]:                           # a setup-token / dying login there: nothing worth protecting
            dest = (svc, acct or login_name(), src)
            break
        l_so, l_o = _ms_left(so, "refreshTokenExpiresAt", t), _ms_left(o, "refreshTokenExpiresAt", t)
        if l_so is None or l_o is None:                         # one side OR BOTH: unknown is never "the default is newer"
            log("WARN", f"sync-back of {ident}: {svc} and the default item differ and "
                        f"{'neither' if l_so is None and l_o is None else 'only one'} of them carries a refresh expiry - "
                        "cannot tell which login is newer")
            return SB_UNSAFE, f"cannot tell which of {svc} and the default item is the newer login"
        if l_so > l_o:
            log("INFO", f"sync-back to {svc} skipped: the stored login is a NEWER one")
            return SB_NOTHING, "the stored login is a newer one"
        dest = (svc, acct or login_name(), src)
        break
    if dest is None:
        dest = (reserve_service(ident), login_name(), None)
    if dry:
        log("INFO", f"DRY-RUN would sync {ident} back to {dest[0]}")
        return SB_DONE, dest[0]
    if verified_write(dest[0], dest[1], with_login(dest[2], cur)):
        log("INFO", f"sync-back: {ident} login copied to {dest[0]} (fp refresh {fp(o.get('refreshToken'))})")
        return SB_DONE, dest[0]
    log("ERROR", f"sync-back to {dest[0]} could not be verified")
    return SB_UNSAFE, f"the write to {dest[0]} could not be verified"


Choice = Tuple[Optional[str], Optional[Tuple[str, str, dict]], str, Optional[Tuple[str, str]]]


def choose(st: dict, dec: dict, ident: str, t: float) -> Choice:
    """(email, source, reason, deferred-alert): who the crews should be on and where its login is. email None = stay where
    they are. The deferred alert (key, text) is sent only after the switch really happened."""
    want = str(dec.get("current") or "").strip().lower()
    if want == ident or not want:
        return None, None, "in sync", None
    src, why, unread = load_source(want, t, st)
    if src:
        return want, src, "follow the pool decision", None
    if unread:           # could not READ it = cannot tell it has none: never fall back on that, exhausted or not (retried every run)
        alert(st, f"unreadable:{want}", f"the pool is on {want} but its login could not be read ({'; '.join(why)}) - the crews "
                                        f"stay on {ident}, nothing is changed", t)
        return None, None, "wanted account could not be read", None
    msg = f"the pool is on {want} but there is no usable full login for it ({'; '.join(why)}) - the crews stay on {ident}"
    if not exhausted(dec, ident, t):
        alert(st, f"no-login:{want}", msg + ". Fix: log {0} in (claude auth login with its CLAUDE_CONFIG_DIR) - a human step".format(want), t)
        return None, None, "wanted account has no full login; current one still has balance", None
    unread_others = []
    for other in accounts():
        if other in (ident, want) or exhausted(dec, other, t):
            continue
        src, _, u = load_source(other, t, st)
        if src:
            return other, src, "fallback", (f"fallback:{other}", f"{ident} is exhausted and the pool's {want} has no full "
                                                                 f"login: crews fall to {other}")
        if u:
            unread_others.append(other)
    alert(st, "stuck", msg + " and no other account has a usable full login"
          + (f" (could not be read: {', '.join(unread_others)})" if unread_others else "") + ": the crews are STUCK", t)
    return None, None, "stuck", None


def heal_choice(st: dict, dec: dict, ident: Optional[str], want: str, t: float) -> Choice:
    """The default item holds no full login (Remote Control is broken): put SOME full login there. The pool's pick first,
    then the account that holds it now, then any account that still has balance."""
    tried, whys = set(), []
    for cand in ([want] if want else []) + ([ident] if ident else []) + list(accounts()):
        if cand in tried or (cand != want and exhausted(dec, cand, t)):
            continue
        tried.add(cand)
        src, why, _ = load_source(cand, t, st)
        if src:
            note = None if cand == want else (f"heal-fallback:{cand}", f"the default item was healed from {cand} because the "
                                              f"pool's {want} was not usable ({'; '.join(whys[:1]) or 'none'})")
            return cand, src, "heal" if cand == want else "heal-fallback", note
        whys.append(f"{cand}: {'; '.join(why)}")
    alert(st, "heal-no-source", f"cannot heal the default item: no account has a usable full login ({' | '.join(whys)}). "
                                f"Fix: log {want or 'one of the accounts'} in (claude auth login with its CLAUDE_CONFIG_DIR) - a human "
                                "step", t)
    return None, None, "heal-no-source", None


def resolve_unverified(st: dict, t: float) -> None:
    """A switch whose source owner the profile could not vouch for is checked here, once the profile CAN answer (the CLI
    has refreshed the token): the right owner is logged, a wrong one is alerted and its source quarantined."""
    un = st.get("unverified")
    if not isinstance(un, dict):
        return
    target, src = un.get("email"), un.get("source")
    age = t - _num(un.get("at"))
    if age > VERIFY_GIVE_UP_S:
        log("WARN", f"the owner of the {target} login taken from {src} is still unverified {int(age)} s after the switch (no "
                    "session refreshed it, or the profile stayed silent) - giving up on verifying it")
        st["unverified_last"] = {"result": "gave-up", "email": target, "at": t}
        st.pop("unverified", None)
        return
    idn = st.get("identity") if isinstance(st.get("identity"), dict) else {}
    if idn.get("via") != "profile":
        return
    owner = idn.get("email")
    if owner == target:
        log("INFO", f"owner verified: the profile confirms the {target} login taken from {src} belongs to {target}")
        st["unverified_last"] = {"result": "verified", "email": target, "at": t}
    else:
        alert(st, f"owner-mismatch:{target}", f"the login written for {target} (from {src}) turned out to belong to {owner} "
              f"(the profile answered after the CLI refreshed it): that source is quarantined and will not be written again "
              f"until it is logged in again; the crews are on {owner}'s account now, not {target}'s", t)
        st.setdefault("bad_sources", {})[str(src)] = {"rfp": un.get("rfp"), "owner": owner, "at": t}
        st["unverified_last"] = {"result": "mismatch", "email": target, "owner": owner, "at": t}
    st.pop("unverified", None)


def _follow(st: dict, dec: dict, user: str, t: float, dry: bool) -> int:
    s, acct, cur = kc_read(DEFAULT_SERVICE)
    if s != "ok":
        log("WARN", f"the default item is {s} (absent, unreadable or holding no login) - NOT touched and NOT healed: "
                    "Remote Control may be down for Mayor and crews")
        if s == "missing":
            alert(st, "default-missing", "the default item does not exist: Remote Control is down for Mayor and crews until a "
                  "login is put back (this script heals only a default item that exists)", t)
        return 0
    ok, why = full_login(cur, t)
    ident = identity(st, cur, t)
    resolve_unverified(st, t)
    want = dec["current"].strip().lower()
    st.update({"target": want, "default_fp": fp(cur["claudeAiOauth"].get("accessToken"))})
    if ident is None and ok:
        log("WARN", "cannot tell whose login the default item holds (profile unanswered) - not touching it")
        return 0
    deferred = None
    if not ok:
        # Remote Control is broken whoever holds the item, so say it every time (the owner being known changes nothing),
        # then put a full login there. Nothing to sync back: the login being left is not a full one.
        alert(st, "default-not-full", f"the default item holds no full login ({why}): Remote Control is broken for Mayor and crews", t)
        if ident:
            st["current"] = ident
        target, src, reason, deferred = heal_choice(st, dec, ident, want, t)
        ident = ident or "(unknown)"
    else:
        st["current"] = ident
        sb, detail = sync_back(st, ident, cur, t, dry)
        target, src, reason, deferred = choose(st, dec, ident, t)
        if target is not None and sb == SB_UNSAFE:
            alert(st, f"sync-back:{ident}", f"sync-back of {ident} could not be completed ({detail}): its refresh token exists "
                  f"only in the default item, so the switch to {target} is refused and the crews STAY on {ident} until it "
                  "can be saved", t)
            return 0
    if target is None or src is None:
        return 0
    svc, sacct, blob = src
    claimed = profile_email(blob["claudeAiOauth"]["accessToken"])
    if claimed is not None and claimed != target:
        alert(st, f"wrong-owner:{target}", f"the item {svc} belongs to {claimed}, not {target} - NOT using it", t)
        return 0
    if dry:
        log("INFO", f"DRY-RUN would switch the crews {ident} -> {target} ({reason}) from {svc}"
                    + ("" if claimed else " [owner unverified: the profile cannot answer for that token]"))
        return 0
    before = bridges()
    if not verified_write(DEFAULT_SERVICE, acct or user, with_login(cur, blob)):
        alert(st, "write-failed", f"could not write the {target} login to the default item (refused, failed or not verified - "
                                  "see the log)", t)
        return 0
    f_new = fp(blob["claudeAiOauth"].get("accessToken"))
    if claimed is None:
        n = int(_num(st.get("unverified_switches"))) + 1
        st["unverified_switches"] = n
        st["identity"] = {"fp": f_new, "email": target, "at": t, "via": "switch-unverified"}
        st["unverified"] = {"email": target, "source": svc, "rfp": fp(blob["claudeAiOauth"].get("refreshToken")), "fp": f_new, "at": t}
        log("WARN", f"source owner unverified: the profile could not say whose the {target} login in {svc} is (its access "
                    f"token is expired); switching anyway (fail-open, unverified switch #{n}) - the owner is checked once the "
                    "CLI has refreshed the token")
    else:
        st["identity"] = {"fp": f_new, "email": target, "at": t, "via": "profile"}
        st.pop("unverified", None)
    st["current"] = target
    st["last_switch"] = {"from": ident, "to": target, "reason": reason, "at": t, "source": svc}
    pv = {"since": t, "to": target, "pids": {str(p): v["bridge"] for p, v in (before or {}).items()},
          "starts": {str(p): v["start"] for p, v in (before or {}).items() if v["start"]},
          "blind": before is None}
    old = st.get("pending_verify")
    if isinstance(old, dict):                                  # the first switch's check was not judged yet: it rides along, it is not dropped
        pv = carry_check(old, pv)
        log("INFO", f"switch to {target}: the check of the switch to {old.get('to')} was still pending "
                    f"({int(t - _num(old.get('since')))} s after it) - its Remote Control bridges are carried into this one "
                    "and judged together, 60 s after this switch")
    elif old is not None:
        pv["blind"] = True                                     # a pending record we cannot read: cannot tell, said at the check
    st["pending_verify"] = pv
    st.setdefault("alerts", {}).pop("rc-lost", None)
    log("INFO", f"SWITCH crews {ident} -> {target} ({reason}); fp access {f_new}; "
                + ("sessions dir unreadable: bridges NOT listed" if before is None else
                   f"{len(pv['pids'])} Remote Control bridges to verify" if not pv["blind"] else
                   f"{len(pv['pids'])} Remote Control bridges listed, but the pending check was blind: it cannot be fully verified"))
    if deferred:
        alert(st, deferred[0], deferred[1], t)
    return 0


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
    st, st_status = load_state()
    if st_status in ("corrupt", "unreadable"):
        log("WARN", f"the state file {state_path()} is {st_status} - starting from an empty state (pending checks and alert "
                    "history are lost)")
        st["state_reset"] = {"at": t, "was": st_status}
    check_bridges(st, t)                                       # first, and on EVERY path: a pending check must not wait for a quiet run
    retry_rc_lost_push(st, t)
    dec = load_json(decision_path())
    if not dec or not isinstance(dec.get("current"), str):
        log("WARN", "no pool decision to follow yet - the crews stay")
        rc = 0
    else:
        # NB: no "is the decision fresh?" gate. `updated` in the pool's file moves only when the pool CHANGES account (measured
        # 06/10: 75 min old while the daemon ran every minute), so age says nothing about whether the daemon is alive. Following
        # an old-but-unchanged decision is correct (the crews are already on it); the pool daemon's liveness is ga-8hcnvb.3's.
        rc = _follow(st, dec, user, t, dry)
    if not dry:
        publish_state(st)
    return rc


def _crash_alert(dry: bool, e: Exception) -> None:
    try:
        st, _ = load_state()
        alert(st, "crash", f"the run crashed ({type(e).__name__}) - see the log for how far it got", now())
        if not dry:
            publish_state(st)
    except Exception:  # noqa: BLE001 - the crash handler of a crash handler has nowhere left to report
        pass


def main(argv: List[str]) -> int:
    global DRY
    dry = DRY = "--dry-run" in argv
    lock = (city() / ".gc" / "claude-crew-account.lock") if city() and (city() / ".gc").is_dir() else state_path().with_suffix(".lock")
    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as e:
        log("ERROR", f"cannot open the lock ({type(e).__name__}) - nothing was done")
        return 1
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("INFO", "another run holds the lock - nothing done this time")
            return 0
        except OSError as e:
            log("ERROR", f"cannot take the lock ({type(e).__name__}) - nothing was done")
            return 1
        try:
            return run_once(dry)
        except Exception as e:  # noqa: BLE001 - a launchd job that crashes silently is the failure this exists to remove
            log("ERROR", f"run failed ({type(e).__name__}: {str(e)[:120]})")
            _crash_alert(dry, e)
            return 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
