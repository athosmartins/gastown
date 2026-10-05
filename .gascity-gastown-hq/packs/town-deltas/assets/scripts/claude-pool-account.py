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
  * the active account answers        -> stay. Failback only to an account that WE saw exhausted (rate-limited, not
                                         key-refused), whose stored reset time has passed, and which outranks the
                                         active one in the order — with NO probe of it (Mayor 04/10: no balance
                                         probe on the way back; if it has not really renewed, its 429 simply
                                         triggers the failover again).
  * the probe could not tell (network, 5xx, anything not 2xx/429/401/403) -> change NOTHING. Error != exhausted.

The switch path never starts `claude` (it may be the thing that is exhausted): the probe is one tiny haiku HTTP
call, and the answer is read from the anthropic-ratelimit-unified-* headers. The probe never follows a redirect (the
Bearer would travel with it): a 30x is "could not tell".

Tokens: read from the vault by lib/claude_account_pool.token_da_conta, held in memory, sent only as the Bearer of
the probe and as the hex of a `security -i` command on STDIN. They are never in argv, env, log, state or output;
accounts are named by e-mail + sha256[:8] fingerprint.

The vault is read LAZILY (Keys): the key of the CURRENT account every run, the keys of the candidates only when the pool
has to move (seed, failover, failback). `token_da_conta` returns None both for "no key registered" and for "vault
unreadable just now", so a None for the current account is NOT "its key is gone": the Keychain item this daemon wrote
(and the fingerprint in the state) is the second witness. Item holds the decision's credential -> keep the decision and
probe THAT token; item cannot be read -> change nothing; item missing or holding something else -> choose again.

KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the run does nothing at all.
SEAMS (tests): CLAUDE_POOL_STATE, CLAUDE_POOL_CRED_DIR (GC_POOL_CRED_DIR, the wrapper's name for it, is honoured too),
CLAUDE_POOL_ACCOUNTS_LIB, CLAUDE_POOL_NOW,
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
MIN_EPOCH = 1_000_000_000         # 2001-09 .. 2100-01-01: what can be an epoch AT ALL. Whether a RESET time is believed is
MAX_EPOCH = 4_102_444_800         # decided against the clock, by _usable_reset: that is the real bound, this is only the floor.
MAX_RETRY_AFTER_S = 31 * 86400    # the furthest ahead ANY reset time (header or retry-after) is believed, from now
DEFAULT_ACCOUNTS_LIB = "/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py"
DEFAULT_STATE = "/Users/athos/shared/data/claude_pool_current_account.json"


# ── config ─────────────────────────────────────────────────────────────────────────────────────────
def now() -> float:
    v = os.environ.get("CLAUDE_POOL_NOW", "")
    try:
        f = _sane_epoch(float(v)) if v else None   # float("nan") parses: a NaN clock makes every comparison False
    except ValueError:
        f = None
    return f if f is not None else time.time()


def _sane_epoch(v) -> Optional[float]:
    """`v` as epoch seconds if it is a real number inside MIN_EPOCH..MAX_EPOCH, else None. Never raises: a value that is not
    a time (None, a bool, a string, NaN, inf, 0, a negative, a 400-digit integer) is 'unknown', not a time."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    try:
        f = float(v)   # an int too big for a float raises OverflowError here (math.isfinite on it would too)
    except OverflowError:
        return None
    return f if math.isfinite(f) and MIN_EPOCH <= f <= MAX_EPOCH else None


def _iso(ts: float) -> str:
    """For log lines and the published `updated`: formatting a time must never be able to crash a run."""
    try:
        return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return "unknown-time"


def city() -> Optional[Path]:
    c = os.environ.get("GC_CITY_PATH", "")
    return Path(c) if c else None


def cred_dir() -> str:
    # The wrapper (claude-lowprio.sh) reads GC_POOL_CRED_DIR; CLAUDE_POOL_CRED_DIR is this daemon's own seam. Both name the
    # item the pool reads, so the daemon honours either - otherwise it could feed an item no session looks at.
    return (os.environ.get("CLAUDE_POOL_CRED_DIR") or os.environ.get("GC_POOL_CRED_DIR")
            or str(Path.home() / ".gastown" / "claude-pool-cred"))


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
    line = f"{_iso(now())} pid={os.getpid()} daemon {level} {msg}"
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
    """A header value (epoch seconds, epoch ms, or ISO-8601) as epoch seconds - or None when it is not a usable time."""
    v = (v or "").strip()
    if not v:
        return None
    try:
        f = float(v)
    except ValueError:
        f = None
    if f is not None:
        return _sane_epoch(f / 1000.0 if f > 1e12 else f)
    try:
        return _sane_epoch(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())
    except (ValueError, OverflowError, OSError):
        return None


def _seconds(v: str) -> Optional[float]:
    """retry-after: a DURATION in seconds, or None."""
    try:
        f = float((v or "").strip())
    except ValueError:
        return None
    return f if math.isfinite(f) and 0 < f <= MAX_RETRY_AFTER_S else None


def _usable_reset(v, t: float) -> Optional[float]:
    """A reset time we will ACT on, or None: a real epoch that is still ahead of `t` and no further than MAX_RETRY_AFTER_S
    from it. A plausible-looking absurdity (year 2096) passes _sane_epoch but would veto the account for decades, and one
    already behind us would read as 'recovered' on the very next run: either way the caller falls back to retry-after,
    then to the cooldown."""
    r = _sane_epoch(v)
    return r if r is not None and t < r <= t + MAX_RETRY_AFTER_S else None


def classify(status: int, headers: Dict[str, str], t: float) -> Probe:
    h = {k.lower(): v for k, v in headers.items()}
    pre = "anthropic-ratelimit-unified-"
    windows = {w: h.get(f"{pre}{w}-status", "") for w in ("5h", "7d")}
    overall = h.get(pre + "status", "")
    rejected = status == 429 or overall == "rejected" or any(v == "rejected" for v in windows.values())
    if rejected:
        claim = h.get(pre + "representative-claim", "")
        resets = [_usable_reset(_epoch(h.get(f"{pre}{w}-reset", "")), t) for w, st in windows.items() if st == "rejected"]
        resets = [r for r in resets if r is not None]
        if not resets:
            by_claim = {"five_hour": "5h", "seven_day": "7d"}.get(claim)
            r = _usable_reset(_epoch(h.get(f"{pre}{by_claim}-reset", "")), t) if by_claim else None
            resets = [r] if r is not None else []
        reset = max(resets) if resets else None
        if reset is None:
            ra = _seconds(h.get("retry-after", ""))
            reset = t + (ra if ra is not None else DEFAULT_COOLDOWN_S)
        return Probe("rejected", reset, claim, f"http={status}")
    if status in (401, 403):
        return Probe("invalid", t + INVALID_KEY_COOLDOWN_S, "", f"http={status}")
    if 200 <= status < 300:
        return Probe("allowed", None, "", f"http={status}")
    return Probe("unknown", None, "", f"http={status}")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """urllib re-sends the request headers - Authorization included - to wherever a 301/302/303 points. Declining the
    redirect makes the 30x surface as an HTTPError, which probe() reads as 'could not tell'."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe(token: str) -> Probe:
    body = json.dumps({"model": PROBE_MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "."}]}).encode()
    req = urllib.request.Request(probe_url(), data=body, method="POST", headers={
        "Authorization": "Bearer " + token, "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20", "content-type": "application/json",
        "user-agent": "claude-pool-account/1"})
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=PROBE_TIMEOUT_S) as r:
            return classify(r.status, dict(r.headers.items()), now())
    except urllib.error.HTTPError as e:   # 4xx/5xx still carry the headers we need
        if 300 <= e.code < 400:   # a redirect is not an answer about the account, whatever headers it carries
            return Probe("unknown", None, "", f"redirect http={e.code} (not followed)")
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
        raw = p.read_bytes()
    except FileNotFoundError:
        return {}
    except OSError as e:
        log("ERROR", f"state file {p} unreadable ({type(e).__name__}) - refusing to act on a decision I cannot see")
        return None
    try:
        d = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):   # not UTF-8 (UnicodeDecodeError is a ValueError), not JSON, or nested past the parser
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


def sanitize_state(st: dict, t: float) -> None:
    """Drop what cannot be trusted, never default it: a missing or garbled reset time must not read as 'already reset'
    (the failback does not probe), a reset further ahead than anything register_exhausted would have stored must not
    veto an account for decades, and a garbled `current` must not read as an account. A reset time already BEHIND `t`
    is kept: that is an account whose time has come, and the failback is what it is for."""
    if "current" in st and not (isinstance(st["current"], str) and st["current"].strip()):
        log("WARN", "state: `current` is not an account name - ignored")
        st.pop("current")
    if "exhausted" not in st:
        return
    ex = st["exhausted"]   # present-but-null is NOT absent: `.get()` cannot tell them apart, and null is not an object either
    if not isinstance(ex, dict):
        log("WARN", "state: `exhausted` is not an object - dropped")
        del st["exhausted"]
        return
    for email in list(ex):
        v = ex[email]
        r = _sane_epoch(v.get("reset_epoch")) if isinstance(v, dict) else None
        if r is None or r > t + MAX_RETRY_AFTER_S:
            log("WARN", f"state: exhausted entry for {email} has no usable reset_epoch - dropped (it is probed again before any use)")
            del ex[email]


def publish_state(st: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    st["schema"] = 1
    st["updated"] = _iso(now())
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


def order_of_use(lib) -> List[str]:
    """The e-mails in the order of use ([] = the usage store gave no order: nothing to rank, so nothing to do)."""
    try:
        order = lib.ordem_das_contas()
        return [e for e in order if isinstance(e, str) and e]
    except Exception as e:  # noqa: BLE001
        log("WARN", f"ordem_das_contas failed ({type(e).__name__}) - nothing to do")
        return []


class Keys:
    """The vault, read lazily and at most once per account per run. `token_da_conta` returns None both for 'no key
    registered' and for 'vault unreadable just now', so a None here means 'no key came back', never 'there is no key':
    the callers that act on it have to say which of the two they are assuming (see current_credential)."""

    def __init__(self, lib):
        self.lib, self._got = lib, {}

    def token(self, email: str) -> Optional[str]:
        if email not in self._got:
            try:
                tok = self.lib.token_da_conta(email)
            except Exception as e:  # noqa: BLE001 - a broken sibling library must not crash the daemon
                log("WARN", f"{email}: the vault read failed ({type(e).__name__})")
                tok = None
            self._got[email] = tok if isinstance(tok, str) and tok else None
        return self._got[email]


def register_exhausted(st: dict, email: str, pr: Probe, t: float) -> None:
    # the sink checks too: whatever a parser let through, only a reset time that is ahead of now and not absurdly far is
    # stored. Anything else is the cooldown - a time already behind us would read as 'recovered' on the very next run.
    reset = _usable_reset(pr.reset_epoch, t)
    if reset is None:
        reset = t + DEFAULT_COOLDOWN_S
    st.setdefault("exhausted", {})[email] = {"reset_epoch": reset, "claim": pr.claim, "seen": t, "why": pr.verdict}
    log("INFO", f"{email} {pr.verdict} ({pr.detail}{', ' + pr.claim if pr.claim else ''}) - unusable until {_iso(reset)}")


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


def pick_next(st: dict, order: List[str], keys: Keys, skip: set, t: float) -> Optional[Tuple[str, str]]:
    """First account of the order that is not known-exhausted, whose key came back from the vault, and that answers a
    probe NOW. Rejected ones are recorded. The vault is asked only for the accounts that get this far."""
    for email in order:
        if email in skip:
            continue
        ex = st.get("exhausted", {}).get(email)
        if ex and ex.get("reset_epoch", math.inf) > t:   # no reset time = still exhausted, never "already reset"
            continue
        tok = keys.token(email)
        if not tok:
            log("INFO", f"{email}: no key came back from the vault this run - not a candidate")
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
    if not (kind == "ok" and held == token):
        log("WARN", f"pool item {'missing' if kind == 'missing' else 'holds fp=' + fingerprint(held or '')} but the decision is "
                    f"{email} fp={fingerprint(token)} - rewriting")
        if not write_item(user, token):
            return
    # The decision names the credential the item holds. If the vault's key for this account changed (rotated), the
    # fingerprint follows - it is the second witness current_credential() relies on when the vault gives nothing back.
    if st.get("fingerprint") != fingerprint(token):
        log("INFO", f"{email}: the key in the vault changed - the decision now carries fp={fingerprint(token)}")
        st["fingerprint"] = fingerprint(token)


def reseed(st: dict, keys: Keys, order: List[str], user: str, t: float, cur: Optional[str]) -> None:
    got = pick_next(st, order, keys, set(), t)
    if got:
        switch_to(st, user, got[0], got[1], f"{'re-seed' if cur else 'seed'}: first usable account ({got[0]})", t)
    else:
        log("WARN", "no account answered a probe - pool item NOT created/changed")


def current_credential(st: dict, keys: Keys, order: List[str], user: str, cur: str) -> Tuple[str, Optional[str]]:
    """The credential of the account the decision names, and where it came from: ('vault', token) | ('item', token) |
    ('gone', None) | ('unknown', None).

    A vault that returns nothing is NOT 'the key is gone' (see Keys): the pool item the daemon wrote is the second witness.
      * item holds a credential whose fingerprint is the decision's -> 'item': keep the decision, the caller probes THAT token;
      * item cannot be read (locked keychain, crashed security)      -> 'unknown': change nothing;
      * item missing, or holding something else                      -> 'gone': nothing corroborates the decision, choose again."""
    tok = keys.token(cur)
    if cur not in order:
        log("INFO", f"current account {cur} is not in the order of use this run - ranked last, not dropped")
    if tok:
        return "vault", tok
    log("WARN", f"current account {cur}: its key did not come from the vault this run - looking at the pool item before deciding anything")
    kind, held = read_item_token(user)
    if kind == "unknown":
        log("WARN", "pool item unreadable (locked keychain?) - the decision is left as it is")
        return "unknown", None
    fp = st.get("fingerprint")
    if kind == "ok" and held and isinstance(fp, str) and fingerprint(held) == fp:
        log("INFO", f"the pool item still holds the decision's credential (fp={fp}) - keeping {cur}, probing that one")
        return "item", held
    log("WARN", f"the pool item {'is missing' if kind == 'missing' else 'holds fp=' + fingerprint(held or '')}, not the credential of "
                f"the decision (fp={fp if isinstance(fp, str) else '-'}) - nothing corroborates {cur}, choosing again")
    return "gone", None


def decide(st: dict, keys: Keys, order: List[str], user: str, t: float) -> None:
    sanitize_state(st, t)
    cur = st.get("current")
    if not cur:
        return reseed(st, keys, order, user, t, None)
    kind, tok = current_credential(st, keys, order, user, cur)
    if kind == "unknown":
        return
    if kind == "gone":
        return reseed(st, keys, order, user, t, cur)

    pr = probe(tok)
    if pr.verdict == "unknown":
        log("INFO", f"{cur}: probe could not tell ({pr.detail}) - nothing changed")
    elif pr.verdict in ("rejected", "invalid"):
        register_exhausted(st, cur, pr, t)
        got = pick_next(st, order, keys, {cur}, t)
        if got:
            switch_to(st, user, got[0], got[1], f"failover: {cur} {pr.verdict}", t)
        else:
            log("WARN", f"no other account could take over (exhausted, no key from the vault this run, or not answering) - staying on {cur}")
    else:
        # active account answers. What it just answered beats anything stored about it.
        ex = st.get("exhausted", {})
        ex.pop(cur, None)
        # Failback: only to an account WE saw exhausted whose stored reset time has passed and which outranks the active
        # one. No probe (the Mayor revoked the confirmation probe): if it has not really renewed, its 429 sends us right
        # back through the branch above. A REFUSED KEY (401/403) is not a limit that renews: failing back to it unprobed
        # would put a still-refused key into the item - every pool session broken until the next run, hourly. It is
        # judged (dropped) at its time like the others, and is probed the normal way when a later failover reaches it.
        # The vault is asked only for the accounts that could be switched to; one whose key does not come back is KEPT
        # (not judged): the failback is tried again on a run that has its key.
        expired = [e for e, v in ex.items() if v.get("reset_epoch", math.inf) <= t]
        recovered = [e for e in expired if ex[e].get("why") != "invalid"]
        kept = set()
        for e in [e for e in order[:order.index(cur) if cur in order else len(order)] if e in recovered]:
            key = keys.token(e)
            if not key:
                kept.add(e)
                log("WARN", f"failback to {e} not done: its key did not come from the vault this run - kept for the next run")
                continue
            if not switch_to(st, user, e, key, f"failback: {e} reached its stored reset time", t):
                kept.add(e)   # the write failed: the failback did NOT happen, so it must be tried again next run
                log("WARN", f"failback to {e} not done (the pool item could not be switched) - kept for the next run")
            break
        for e in expired:
            if e not in kept:
                ex.pop(e, None)   # judged now; a later rejection re-registers it with a fresh time
    now_cur = st.get("current")
    if kind == "item" and now_cur == cur:
        return   # the key of the decision never came from the vault and the item IS that key: nothing to heal against
    key = keys.token(now_cur) if now_cur else None
    if key:
        heal_item(st, user, key, now_cur)


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
    order = order_of_use(lib)
    if not order:
        log("WARN", "no account in the order of use (usage store unreadable or empty) - nothing changed")
        return 0
    st = load_state()
    if st is None:
        return 1
    before = json.dumps(st, sort_keys=True)
    decide(st, Keys(lib), order, user, now())
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
