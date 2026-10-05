#!/usr/bin/env python3
"""claude-pool-account — ga-8hcnvb.1: which Claude account the headless pool runs on, as DATA.

The pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner) is launched through
claude-lowprio.sh, which points each session at a Keychain item (CLAUDE_SECURESTORAGE_CONFIG_DIR). claude
re-reads that item every ~30 s, so rewriting it moves every LIVE pool session to another account with no restart
and no lost conversation (measured, ga-2yyitx). This script is the SINGLE WRITER of that item and of the decision
the WhatsApp services read (`current` in CLAUDE_POOL_STATE).

One run (launchd StartInterval, single instance via flock):
  * no usable decision yet            -> seed with the first account of the order that answers a probe.
  * the active account is REJECTED    -> failover: first account of the order that is not known-exhausted and
    (HTTP 429 / a *-status of "rejected")   answers a probe. The rejection's reset time is stored.
  * the active account answers        -> stay. Failback only to an account that WE saw exhausted, whose stored
                                         reset time has passed, and which outranks the active one in the order —
                                         with NO probe of it (Mayor 04/10: no balance probe on the way back; if it
                                         has not really renewed, its 429 simply triggers the failover again).
  * the probe could not tell (network, 5xx, anything not 2xx/429/401/403) -> change NOTHING. Error != exhausted.

The switch path never starts `claude` (it may be the thing that is exhausted): the probe is one tiny haiku HTTP
call, and the answer is read from the anthropic-ratelimit-unified-* headers.

Tokens: read from the vault by lib/claude_account_pool.token_da_conta, held in memory, sent only as the Bearer of
the probe and as the hex of a `security -i` command on STDIN. They are never in argv, env, log, state or output;
accounts are named by e-mail + sha256[:8] fingerprint.

KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the run does nothing at all.
SEAMS (tests): CLAUDE_POOL_STATE, CLAUDE_POOL_CRED_DIR, CLAUDE_POOL_ACCOUNTS_LIB, CLAUDE_POOL_NOW,
CLAUDE_POOL_PROBE_URL (honoured ONLY for a loopback host — an env var must not be able to aim a token elsewhere).
"""
from __future__ import annotations

import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import pwd
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

PROBE_URL = "https://api.anthropic.com/v1/messages"
PROBE_MODEL = "claude-haiku-4-5-20251001"
PROBE_TIMEOUT_S = 10
DEFAULT_COOLDOWN_S = 900          # rejected with no usable reset header
INVALID_KEY_COOLDOWN_S = 3600     # 401/403: the key itself is refused
EXPIRES_AT_MS = 4102444800000     # 2100-01-01: the blob carries no refresh token, so it never rotates
DEFAULT_ACCOUNTS_LIB = "/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py"
DEFAULT_STATE = "/Users/athos/shared/data/claude_pool_current_account.json"


# ── config ─────────────────────────────────────────────────────────────────────────────────────────
def now() -> float:
    v = os.environ.get("CLAUDE_POOL_NOW", "")
    try:
        return float(v) if v else time.time()
    except ValueError:
        return time.time()


def city() -> Optional[Path]:
    c = os.environ.get("GC_CITY_PATH", "")
    return Path(c) if c else None


def cred_dir() -> str:
    return os.environ.get("CLAUDE_POOL_CRED_DIR") or str(Path.home() / ".gastown" / "claude-pool-cred")


def item_service() -> str:
    # claude names the Keychain item "Claude Code-credentials-" + first 8 hex of sha256(CLAUDE_SECURESTORAGE_CONFIG_DIR)
    return "Claude Code-credentials-" + hashlib.sha256(cred_dir().encode()).hexdigest()[:8]


def state_path() -> Path:
    return Path(os.environ.get("CLAUDE_POOL_STATE") or DEFAULT_STATE)


def lock_path() -> Optional[Path]:
    c = city()
    return c / ".gc" / "claude-pool-account.lock" if c and (c / ".gc").is_dir() else None


# The Keychain "account" claude asks for is the login name. It is interpolated into a `security -i` command LINE
# (stdin), so anything but a plain login name — a quote, a newline, a backslash — would be a second command.
USER_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,63}")


def login_name() -> str:
    u = os.environ.get("USER", "")
    if u:
        return u
    try:
        return pwd.getpwuid(os.getuid()).pw_name   # os.getlogin() needs a controlling tty: it raises under launchd
    except (KeyError, OSError):
        return ""


def valid_user(u: str) -> bool:
    return USER_RE.fullmatch(u) is not None


def probe_url() -> str:
    u = os.environ.get("CLAUDE_POOL_PROBE_URL", "")
    if u:
        host = urllib.parse.urlparse(u).hostname or ""
        if host in ("127.0.0.1", "localhost", "::1"):
            return u
        log("WARN", f"ignoring CLAUDE_POOL_PROBE_URL host={host!r}: only loopback is honoured")
    return PROBE_URL


def fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()[:8]


# ── log (never a token) ───────────────────────────────────────────────────────────────────────────
def log(level: str, msg: str) -> None:
    if "sk-ant-" in msg:
        msg = "[line withheld: token-shaped text]"
    line = f"{datetime.fromtimestamp(now(), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} pid={os.getpid()} daemon {level} {msg}"
    c = city()
    try:
        if c and (c / ".gc" / "logs").is_dir():
            with open(c / ".gc" / "logs" / "claude-pool-account.log", "a") as f:
                f.write(line + "\n")
            return
    except OSError:
        pass
    print(line, file=sys.stderr)


# ── the accounts library (whatsapp_automation/lib/claude_account_pool.py) ─────────────────────────
def load_accounts_lib():
    p = os.environ.get("CLAUDE_POOL_ACCOUNTS_LIB") or DEFAULT_ACCOUNTS_LIB
    if not Path(p).is_file():
        log("WARN", f"accounts library not found at {p} - nothing to do")
        return None
    spec = importlib.util.spec_from_file_location("claude_account_pool_ext", p)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:  # noqa: BLE001 - a broken sibling library must not crash the daemon
        log("WARN", f"accounts library failed to import ({type(e).__name__}) - nothing to do")
        return None
    return mod


# ── probe ──────────────────────────────────────────────────────────────────────────────────────────
class Probe:
    """verdict: allowed | rejected | invalid | unknown.  `unknown` means 'could not tell' and never changes anything."""

    def __init__(self, verdict: str, reset_epoch: Optional[float] = None, claim: str = "", detail: str = ""):
        self.verdict, self.reset_epoch, self.claim, self.detail = verdict, reset_epoch, claim, detail


def _epoch(v: str) -> Optional[float]:
    v = (v or "").strip()
    if not v:
        return None
    try:
        f = float(v)
        return f / 1000.0 if f > 1e12 else f
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def classify(status: int, headers: Dict[str, str], t: float) -> Probe:
    h = {k.lower(): v for k, v in headers.items()}
    pre = "anthropic-ratelimit-unified-"
    windows = {w: h.get(f"{pre}{w}-status", "") for w in ("5h", "7d")}
    overall = h.get(pre + "status", "")
    rejected = status == 429 or overall == "rejected" or any(v == "rejected" for v in windows.values())
    if rejected:
        claim = h.get(pre + "representative-claim", "")
        resets = [_epoch(h.get(f"{pre}{w}-reset", "")) for w, st in windows.items() if st == "rejected"]
        resets = [r for r in resets if r]
        if not resets:
            by_claim = {"five_hour": "5h", "seven_day": "7d"}.get(claim)
            r = _epoch(h.get(f"{pre}{by_claim}-reset", "")) if by_claim else None
            resets = [r] if r else []
        reset = max(resets) if resets else None
        if reset is None:
            ra = _epoch(h.get("retry-after", ""))
            reset = t + ra if ra and ra < 1e9 else t + DEFAULT_COOLDOWN_S
        return Probe("rejected", reset, claim, f"http={status}")
    if status in (401, 403):
        return Probe("invalid", t + INVALID_KEY_COOLDOWN_S, "", f"http={status}")
    if 200 <= status < 300:
        return Probe("allowed", None, "", f"http={status}")
    return Probe("unknown", None, "", f"http={status}")


def probe(token: str) -> Probe:
    body = json.dumps({"model": PROBE_MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "."}]}).encode()
    req = urllib.request.Request(probe_url(), data=body, method="POST", headers={
        "Authorization": "Bearer " + token, "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20", "content-type": "application/json",
        "user-agent": "claude-pool-account/1"})
    try:
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as r:
            return classify(r.status, dict(r.headers.items()), now())
    except urllib.error.HTTPError as e:   # 4xx/5xx still carry the headers we need
        return classify(e.code, dict(e.headers.items()) if e.headers else {}, now())
    except Exception as e:  # noqa: BLE001 - network down, DNS, TLS, timeout: could not tell
        return Probe("unknown", None, "", f"{type(e).__name__}")


# ── the Keychain item ──────────────────────────────────────────────────────────────────────────────
def write_item(user: str, token: str) -> bool:
    """Rewrite the pool item. The secret travels only on `security -i`'s STDIN (hex data): never in argv."""
    if not valid_user(user):   # run_once checks this first; here too because this is where the command line is built
        log("ERROR", "refusing to build a security command for an account name that is not a plain login name")
        return False
    blob ={"claudeAiOauth": {"accessToken": token, "expiresAt": EXPIRES_AT_MS,
                              "scopes": ["user:inference"], "subscriptionType": None}}
    hexdata = json.dumps(blob).encode().hex()
    cmd = f'add-generic-password -U -a "{user}" -s "{item_service()}" -X {hexdata}\n'
    try:
        r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        log("ERROR", f"security -i failed to run ({type(e).__name__})")
        return False
    if r.returncode != 0:
        log("ERROR", f"security -i exit={r.returncode}")
        return False
    return True


def read_item_token(user: str) -> Tuple[str, Optional[str]]:
    """('ok', token) | ('missing', None) | ('unknown', None). Only exit 44 means the item is not there: a locked
    keychain or a crashed `security` is 'could not tell', and 'could not tell' must never trigger a rewrite."""
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", user, "-s", item_service(), "-w"],
                           capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return "unknown", None
    if r.returncode == 44:
        return "missing", None
    if r.returncode != 0:
        return "unknown", None
    try:
        tok = json.loads(r.stdout.strip())["claudeAiOauth"]["accessToken"]
    except (ValueError, KeyError, TypeError):
        return "unknown", None   # something else lives there: do not guess, the next run will look again
    return ("ok", tok) if isinstance(tok, str) else ("unknown", None)


# ── state ──────────────────────────────────────────────────────────────────────────────────────────
def load_state() -> Optional[dict]:
    """{} = no decision yet (absent, or corrupt and moved aside). None = the file is there but cannot be READ now
    (permissions, I/O): the caller must not act, because acting would overwrite a decision it could not see."""
    p = state_path()
    try:
        text = p.read_text()
    except FileNotFoundError:
        return {}
    except OSError as e:
        log("ERROR", f"state file {p} unreadable ({type(e).__name__}) - refusing to act on a decision I cannot see")
        return None
    try:
        d = json.loads(text)
    except ValueError:
        d = None
    if isinstance(d, dict):
        return d
    aside = p.with_name(p.name + f".corrupt.{int(now())}")   # keep the evidence; never silently overwrite it
    try:
        os.replace(p, aside)
    except OSError as e:
        log("ERROR", f"state file {p} is corrupt and could not be moved aside ({type(e).__name__}) - refusing to act")
        return None
    log("WARN", f"state file {p} is not a JSON object - moved to {aside.name}, starting empty")
    return {}


def _real_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def sanitize_state(st: dict) -> None:
    """Drop what cannot be trusted, never default it: a missing or garbled reset time must not read as 'already reset'
    (the failback does not probe), and a garbled `current` must not read as an account."""
    if "current" in st and not (isinstance(st["current"], str) and st["current"].strip()):
        log("WARN", "state: `current` is not an account name - ignored")
        st.pop("current")
    ex = st.get("exhausted")
    if ex is None:
        return
    if not isinstance(ex, dict):
        log("WARN", "state: `exhausted` is not an object - dropped")
        st.pop("exhausted")
        return
    for email in list(ex):
        v = ex[email]
        if not (isinstance(v, dict) and _real_number(v.get("reset_epoch"))):
            log("WARN", f"state: exhausted entry for {email} has no usable reset_epoch - dropped (it is probed again before any use)")
            del ex[email]


def publish_state(st: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    st["schema"] = 1
    st["updated"] = datetime.fromtimestamp(now(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(st, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, p)


# ── one run ────────────────────────────────────────────────────────────────────────────────────────
def disabled() -> Optional[str]:
    if os.environ.get("GC_POOL_ACCOUNT") == "0":
        return "GC_POOL_ACCOUNT=0"
    c = city()
    if c and (c / ".gc" / "no-pool-account").exists():
        return str(c / ".gc" / "no-pool-account")
    return None


def usable_accounts(lib) -> List[Tuple[str, str]]:
    """[(email, token)] in the order of use, only accounts whose key the vault returned."""
    try:
        order = lib.ordem_das_contas()
    except Exception as e:  # noqa: BLE001
        log("WARN", f"ordem_das_contas failed ({type(e).__name__}) - nothing to do")
        return []
    out = []
    for email in order:
        tok = lib.token_da_conta(email)
        if tok:
            out.append((email, tok))
    return out


def register_exhausted(st: dict, email: str, pr: Probe, t: float) -> None:
    reset = pr.reset_epoch
    if reset is None or reset <= t:
        reset = t + DEFAULT_COOLDOWN_S   # a reset already in the past would read as 'recovered' on the very next run
    st.setdefault("exhausted", {})[email] = {"reset_epoch": reset, "claim": pr.claim, "seen": t, "why": pr.verdict}
    log("INFO", f"{email} {pr.verdict} ({pr.detail}{', ' + pr.claim if pr.claim else ''}) - unusable until "
                f"{datetime.fromtimestamp(reset, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")


def switch_to(st: dict, user: str, email: str, token: str, reason: str, t: float) -> bool:
    if not write_item(user, token):
        return False
    kind, back = read_item_token(user)
    # three answers, three outcomes: it holds the credential / it holds something else (or nothing) / I could not look.
    if kind == "ok" and back != token:
        log("ERROR", f"item written for {email} but it holds another credential (fp={fingerprint(back or '')}) - decision NOT changed")
        return False
    if kind == "missing":
        log("ERROR", f"item written for {email} but not found afterwards - decision NOT changed")
        return False
    if kind != "ok":
        # security reported success but the Keychain cannot be read back (locked?). Not a mismatch: the decision follows
        # the write, and the next run's heal_item looks again and rewrites if the item does not hold the decision.
        log("WARN", f"item written for {email} (security reported success) but the read-back was unreadable - switch unverified")
    prev = st.get("current")
    st.update(current=email, fingerprint=fingerprint(token), since=t, reason=reason, previous=prev)
    st.get("exhausted", {}).pop(email, None)
    log("INFO", f"SWITCH {prev or '-'} -> {email} fp={fingerprint(token)}: {reason}")
    return True


def pick_next(st: dict, accts: List[Tuple[str, str]], skip: set, t: float) -> Optional[Tuple[str, str]]:
    """First account of the order that is not known-exhausted and answers a probe NOW. Rejected ones are recorded."""
    for email, tok in accts:
        if email in skip:
            continue
        ex = st.get("exhausted", {}).get(email)
        if ex and ex.get("reset_epoch", math.inf) > t:   # no reset time = still exhausted, never "already reset"
            continue
        pr = probe(tok)
        if pr.verdict == "allowed":
            return email, tok
        if pr.verdict in ("rejected", "invalid"):
            register_exhausted(st, email, pr, t)
        else:
            log("INFO", f"{email} fp={fingerprint(tok)} probe={pr.verdict} {pr.detail} - not a candidate this run")
    return None


def heal_item(st: dict, user: str, token: str, email: str) -> None:
    """The daemon is the single writer: if the item is gone or holds another account than the decision, put it back."""
    kind, held = read_item_token(user)
    if kind == "unknown":
        log("WARN", "pool item unreadable (locked keychain?) - not touched")
        return
    if kind == "ok" and held == token:
        return
    log("WARN", f"pool item {'missing' if kind == 'missing' else 'holds fp=' + fingerprint(held or '')} but the decision is "
                f"{email} fp={fingerprint(token)} - rewriting")
    write_item(user, token)


def decide(st: dict, accts: List[Tuple[str, str]], user: str, t: float) -> None:
    sanitize_state(st)
    by_email = dict(accts)
    order = [e for e, _ in accts]
    cur = st.get("current")
    if not cur or cur not in by_email:
        if cur:
            log("WARN", f"current account {cur} has no usable key any more - choosing again")
        got = pick_next(st, accts, set(), t)
        if got:
            switch_to(st, user, got[0], got[1], f"{'re-seed' if cur else 'seed'}: first usable account ({got[0]})", t)
        else:
            log("WARN", "no account answered a probe - pool item NOT created/changed")
        return

    pr = probe(by_email[cur])
    if pr.verdict == "unknown":
        log("INFO", f"{cur}: probe could not tell ({pr.detail}) - nothing changed")
    elif pr.verdict in ("rejected", "invalid"):
        register_exhausted(st, cur, pr, t)
        got = pick_next(st, accts, {cur}, t)
        if got:
            switch_to(st, user, got[0], got[1], f"failover: {cur} {pr.verdict}", t)
        else:
            log("WARN", f"every account is exhausted or unreachable - staying on {cur}")
    else:
        # active account answers. Failback: only to an account WE saw exhausted whose stored reset time has passed
        # and which outranks the active one. No probe (the Mayor revoked the confirmation probe): if it has not
        # really renewed, its 429 sends us right back through the branch above.
        recovered = [e for e, v in st.get("exhausted", {}).items() if v.get("reset_epoch", math.inf) <= t and e in by_email]
        best = next((e for e in order if e in recovered), None)
        kept = None
        if best and order.index(best) < order.index(cur):
            if not switch_to(st, user, best, by_email[best], f"failback: {best} reached its stored reset time", t):
                kept = best   # the write failed: the failback did NOT happen, so it must be tried again next run
                log("WARN", f"failback to {best} not done (the pool item could not be switched) - kept for the next run")
        for e in recovered:
            if e != kept:
                st.get("exhausted", {}).pop(e, None)   # judged now; a later rejection re-registers it with a fresh time
    cur = st.get("current")
    if cur in by_email:
        heal_item(st, user, by_email[cur], cur)


def run_once() -> int:
    off = disabled()
    if off:
        log("INFO", f"disabled by {off} - nothing done")
        return 0
    # Single writer, so the lock FAILS CLOSED: no lock = no run. (Exit 1, not 0: 'refused because misconfigured' must not
    # look like 'ran and had nothing to do' to launchd.) Only real contention is a quiet exit 0.
    lp = lock_path()
    if lp is None:
        log("ERROR", "no usable GC_CITY_PATH/.gc - cannot take the single-instance lock, refusing to run unlocked")
        return 1
    try:
        lock_fd = open(lp, "w")
    except OSError as e:
        log("ERROR", f"cannot open the lock file {lp} ({type(e).__name__}) - refusing to run unlocked")
        return 1
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            log("INFO", "another run holds the lock - exiting")
            return 0
        log("ERROR", f"flock failed (errno={e.errno}) - refusing to run unlocked")
        return 1
    user = login_name()
    if not valid_user(user):
        log("ERROR", "the login name is empty or not a plain name - refusing to build a Keychain command from it")
        return 1
    lib = load_accounts_lib()
    if lib is None:
        return 0
    accts = usable_accounts(lib)
    if not accts:
        log("WARN", "no account with a usable key (order empty or vault unreadable) - nothing changed")
        return 0
    st = load_state()
    if st is None:
        return 1
    before = json.dumps(st, sort_keys=True)
    decide(st, accts, user, now())
    if json.dumps(st, sort_keys=True) != before:
        publish_state(st)
    return 0


def main(argv: List[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "run-once"
    if cmd == "run-once":
        try:
            return run_once()
        except Exception as e:  # noqa: BLE001 - last resort: log the TYPE only, never a message that could hold a token
            log("ERROR", f"unhandled {type(e).__name__} in run-once")
            return 1
    print("usage: claude-pool-account.py run-once", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
