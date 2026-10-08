#!/usr/bin/env python3
"""claude-pool-account — ga-8hcnvb.1: which Claude account the headless pool runs on, as DATA.

The pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner) is launched through
claude-lowprio.sh, which points each session at a Keychain item (CLAUDE_SECURESTORAGE_CONFIG_DIR). claude
re-reads that item every ~30 s, so rewriting it moves every LIVE pool session to another account with no restart
and no lost conversation (measured, ga-2yyitx). This script is the SINGLE WRITER of that item, of the credentials file beside it
(next paragraph) and of the decision the WhatsApp services read (`current` in CLAUDE_POOL_STATE).

The item is not the only thing a session can read (ga-6gat1o). When claude cannot read the Keychain item - the Keychain is locked in the
context the session runs in - it falls back to the plaintext <CLAUDE_SECURESTORAGE_CONFIG_DIR>/.credentials.json, and whatever login THAT
file holds is the account the session runs on, whatever the item says. So the decision is written to both, in the same step: a switch that
reaches only the item moves nothing for such a session (08/10: the whole pool sat 2h20 on an account whose weekly limit was spent, while
the item held another one). heal_item looks at both on every run; a file that holds another credential than the decision's - a login
someone did in the pool dir, a stale copy - is logged (WARN, with what it looks like) and rewritten.

One run (launchd StartInterval, single instance via flock):
  * no usable decision yet            -> seed with the first account of the order that answers a probe.
  * the active account is REJECTED    -> failover: first account of the order that is not known-exhausted and
    (HTTP 429 / a *-status of "rejected")   answers a probe. The rejection's reset time is stored.
  * the active account answers        -> stay. Failback only to an account that WE saw exhausted (rate-limited, not
                                         key-refused), whose stored reset time has passed, whose usage reading in
                                         the usage store was taken AFTER that reset, and which that fresh reading
                                         ranks ahead of the active one — with NO probe of it (Mayor 04/10: no
                                         balance probe on the way back; if it has not really renewed, its 429 simply
                                         triggers the failover again).
  * the probe could not tell (network, 5xx, anything not 2xx/429/401/403) -> no failover and no failback: the DECISION does
    not change. Error != exhausted. (The run still goes on to heal_item, which may put the item back to the decision
    already taken - the item following the decision, not the probe changing it.)

The order of use comes from the usage store, which the collector rewrites every ~30 min while this daemon runs every
minute: at the reset tick the order can be half an hour old, and a reading taken BEFORE the reset says nothing about the
account AFTER it ("not known" is not "does not outrank"). So an expired entry is never judged by the order alone:
  * no good reading of that account taken after its reset -> the entry is KEPT and the log says it is waiting for the
    next collection; the next run asks again;
  * a good reading taken after the reset                  -> the order decides: fail back if the account ranks ahead
    of the active one, otherwise drop the entry - with a log line saying why.
Every removal of an entry from the registry has a log line with its reason; nothing leaves it silently.

The switch path never starts `claude` (it may be the thing that is exhausted): the probe is one tiny HTTP call (1 token, on the
model the pool runs, as Claude Code would ask for it), and the answer is read from the anthropic-ratelimit-unified-* headers. The probe never follows a redirect (the
Bearer would travel with it): a 30x is "could not tell".

Tokens: read from the vault by lib/claude_account_pool.token_da_conta, held in memory, sent only as the Bearer of
the probe and as the hex of a `security -i` command on STDIN. They are never in argv, env, log, state or output;
accounts are named by e-mail + sha256[:8] fingerprint.

The vault is read LAZILY (Keys): the key of the CURRENT account every run, the keys of the candidates only when the pool
has to move (seed, failover, failback). `token_da_conta` returns None both for "no key registered" and for "vault
unreadable just now", so a None for the current account is NOT "its key is gone": the Keychain item this daemon wrote
(and the fingerprint in the state) is the second witness. Item holds the decision's credential -> keep the decision and
probe THAT token; item cannot be read -> change nothing; item missing or holding something else -> choose again.

KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the run does nothing at all. So does <city>/.gc/pool-account-degraded,
which is not a knob: claude-pool-guard.py (ga-8hcnvb.3) writes it when the per-version self-test says the installed claude no
longer reads the pool item, and removes it when the test passes again.
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
PROBE_MODEL = "claude-sonnet-5-5"   # what the pool runs (--model sonnet): a limit that applies to Sonnet and not to haiku must show up in the probe (ga-6gat1o)
PROBE_SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude."   # the first system block Claude Code sends: an OAuth credential is issued for its requests
PROBE_TIMEOUT_S = 10
CRED_FILE_NAME = ".credentials.json"   # in the pool dir: what claude falls back to when it cannot read the Keychain item (ga-6gat1o)
DEFAULT_COOLDOWN_S = 900          # rejected with no usable reset header
INVALID_KEY_COOLDOWN_S = 3600     # 401/403: the key itself is refused
EXPIRES_AT_MS = 4102444800000     # 2100-01-01: the blob carries no refresh token, so it never rotates
MIN_EPOCH = 1_000_000_000         # 2001-09 .. 2100-01-01: what can be an epoch AT ALL. Whether a RESET time is believed is
MAX_EPOCH = 4_102_444_800         # decided against the clock, by _usable_reset: that is the real bound, this is only the floor.
MAX_RETRY_AFTER_S = 31 * 86400    # the furthest ahead ANY reset time (header or retry-after) is believed, from now
CLOCK_SKEW_S = 300                # a usage reading stamped further ahead than this has not been taken yet: it is not a reading
POOL_ITEM_RE = re.compile(r"Claude Code-credentials-[0-9a-f]{8}")   # the POOL's item. The bare "Claude Code-credentials" is Mayor's/crews'
DEFAULT_ACCOUNTS_LIB = "/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py"
DEFAULT_STATE = "/Users/athos/shared/data/claude_pool_current_account.json"
DEGRADED_MARKER = "pool-account-degraded"          # in <city>/.gc: written/removed by claude-pool-guard.py only
HEARTBEAT_FILE = "claude-pool-account.heartbeat"   # in <city>/.gc: written by a run that finished cleanly


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
    # claude names the Keychain item "Claude Code-credentials-" + first 8 hex of sha256(CLAUDE_SECURESTORAGE_CONFIG_DIR).
    # This daemon touches THAT item only - the pool's, hashed from a fixed directory only pool sessions are pointed at. The
    # default item, plain "Claude Code-credentials" (no suffix), is Mayor's and the crews': a setup-token written there kills
    # their Remote Control (Athos 05/10). The suffix is always appended here so the two names cannot meet, and write_item
    # refuses any service name that is not "-<8 hex>" (POOL_ITEM_RE) on top of that.
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
ERRORS_THIS_RUN = 0   # ERROR lines logged by this process: a run that logged one is not a clean run (see write_heartbeat)


def log(level: str, msg: str) -> None:
    global ERRORS_THIS_RUN
    if level == "ERROR":
        ERRORS_THIS_RUN += 1
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
    """verdict: allowed | rejected | invalid | unknown.  `unknown` means 'could not tell': it never triggers a failover or a
    failback. (The run still goes on to heal_item, which may put the item back to the decision already taken - that is
    the item following the decision, not the probe changing it.)"""

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
    body = json.dumps({"model": PROBE_MODEL, "max_tokens": 1, "system": [{"type": "text", "text": PROBE_SYSTEM}],
                       "messages": [{"role": "user", "content": "."}]}).encode()
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
def _blob(token: str) -> dict:
    """The credential as claude stores it - in the Keychain item and in the credentials file alike: inference-only, no refresh token."""
    return {"claudeAiOauth": {"accessToken": token, "expiresAt": EXPIRES_AT_MS,
                              "scopes": ["user:inference"], "subscriptionType": None}}


def write_item(user: str, token: str) -> bool:
    """Rewrite the pool item. The secret travels only on `security -i`'s STDIN (hex data): never in argv."""
    if not valid_user(user):   # run_once checks this first; here too because this is where the command line is built
        log("ERROR", "refusing to build a security command for an account name that is not a plain login name")
        return False
    if not POOL_ITEM_RE.fullmatch(item_service()):   # the writer is where a wrong item would do damage: never Mayor's/crews' default one
        log("ERROR", "refusing to write a Keychain item that is not the pool's hashed one")
        return False
    hexdata = json.dumps(_blob(token)).encode().hex()
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


# ── the credentials file (ga-6gat1o) ───────────────────────────────────────────────────────────────
# claude reads the Keychain item first; where it cannot (a Keychain locked in the context of the session) it reads THIS file. A switch that
# reached only the item moved nothing for such a session, so the file is written and healed with the same rigour as the item.
def cred_file() -> Path:
    return Path(cred_dir()) / CRED_FILE_NAME


def _cred_dir_refusal() -> Optional[str]:
    """Why the credentials file must NOT be written in cred_dir() (None = it may). The writer is where a wrong file does damage, and the
    wrong file is Mayor's or a crew's own login (a setup-token over it kills their Remote Control - see item_service): so the pool dir
    has to be an absolute path that is neither the home directory nor a claude config directory (~/.claude, or CLAUDE_CONFIG_DIR)."""
    d = Path(cred_dir())
    if not d.is_absolute():
        return "the pool dir is not an absolute path"
    # vazio → no CLAUDE_CONFIG_DIR: only the home directory and ~/.claude are ruled out; falhou/ilegível → no home directory to compare with, or a
    # path the OS refuses to resolve, is "could not tell where the pool dir points": refused, never "safe"
    try:
        home = Path.home()
        ruled_out = {home, home / ".claude"}
        if os.environ.get("CLAUDE_CONFIG_DIR"):
            ruled_out.add(Path(os.environ["CLAUDE_CONFIG_DIR"]))
        if os.path.realpath(d) in {os.path.realpath(p) for p in ruled_out}:
            return "the pool dir is the home directory or a claude config directory, where the Mayor's/crews' own login lives"
    except (OSError, RuntimeError, ValueError):
        return "could not tell where the pool dir points"
    return None


def read_cred_file() -> Tuple[str, Optional[str]]:
    """('ok', token) | ('missing', None) | ('unknown', None) - read_item_token's three answers for the file. Only "there is no such file" and
    "the file is empty" are 'missing' (writing then destroys nothing). A file that cannot be read, or that holds something this cannot make a
    credential of, is 'unknown': the heal does not overwrite what cannot be read (it could be a login this does not understand). A switch is a
    deliberate move of the whole pool and writes the file either way, as it writes the item."""
    p = cred_file()
    # vazio → a file of zero (or only blank) bytes is 'missing': nothing there to lose; falhou/ilegível → only FileNotFoundError is 'missing', any
    # other OSError (permissions, I/O, a directory in its place, a parent that is a file) is 'unknown': "could not look" never triggers a rewrite
    try:
        raw = p.read_bytes()
    except FileNotFoundError:
        return "missing", None
    except OSError:
        return "unknown", None
    if not raw.strip():
        return "missing", None
    # vazio → no accessToken (or an empty one) is 'unknown', not 'missing': there IS something in the file; falhou/ilegível → not UTF-8, not JSON,
    # nested past the parser or another shape is 'unknown' too: not guessed at, the next run looks again
    try:
        tok = json.loads(raw.decode("utf-8"))["claudeAiOauth"]["accessToken"]
    except (ValueError, KeyError, TypeError, RecursionError):
        return "unknown", None
    return ("ok", tok) if isinstance(tok, str) and tok else ("unknown", None)


def write_cred_file(token: str) -> bool:
    """Put the credential in the pool dir's credentials file. Atomic: a temp file beside it, created 0600 (never wider, not even for a moment),
    fsynced, renamed over it - a session reads the old file or the new one, never half of one. The token is in the file and in this process's
    memory only: not in argv, not in a log line."""
    why = _cred_dir_refusal()
    if why:
        log("ERROR", f"refusing to write the credentials file: {why}")
        return False
    p = cred_file()
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    try:
        p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            tmp.unlink()   # a leftover of a crashed run that had this pid: O_EXCL below would refuse to reuse it
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)   # exactly 0600 whatever the umask is
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(_blob(token)))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)
    except OSError as e:
        log("ERROR", f"credentials file not written ({type(e).__name__})")
        try:
            tmp.unlink()
        except OSError:
            pass
        return False
    return True


def put_cred_file(token: str) -> bool:
    """write_cred_file, then LOOK: the file has to read back as this credential. It is a local file, so a read that does not say so is a
    failure - not 'unverified', which is what a locked Keychain earns."""
    if not write_cred_file(token):
        return False
    # vazio → 'missing' after a write that reported success: the credential is not there, False; falhou/ilegível → 'unknown' is False too: the
    # caller keeps the decision where it was and the next run looks again
    kind, back = read_cred_file()
    if kind == "ok" and back == token:
        return True
    log("ERROR", f"credentials file written but it does not read back as the decision's credential "
                 f"({'fp=' + fingerprint(back) if kind == 'ok' and back else 'no credential in it'})")
    return False


def heal_cred_file(token: str, email: str) -> bool:
    """The credentials file must hold the decision's credential, as the item must (heal_item). True = it does: it did, or it was put back."""
    # vazio → 'missing': the file is written (a pool dir that never had one is how every first run starts); falhou/ilegível → 'unknown': ERROR and
    # nothing written - the pool may be running on whatever that file holds, and that stays visible (no clean-run heartbeat) until it can be read
    kind, held = read_cred_file()
    if kind == "unknown":
        log("ERROR", "pool credentials file cannot be read as a credential (permissions, I/O, or something else in it) - not touched; a session "
                     "that cannot read the Keychain item runs on whatever it holds")
        return False
    if kind == "ok" and held == token:
        return True
    log("WARN", f"pool credentials file {'missing' if kind == 'missing' else 'holds fp=' + fingerprint(held or '')} but the decision is "
                f"{email} fp={fingerprint(token)} - rewriting")
    if kind == "ok":   # a login somebody else did in the pool dir: say what it looks like BEFORE the rewrite erases the evidence (as heal_item does for the item)
        log("WARN", f"foreign login in the pool credentials file (fp={fingerprint(held or '')}): {describe_foreign_file()}")
    return put_cred_file(token)


MDAT_RE = re.compile(r'"mdat"<timedate>=(?:0x[0-9A-Fa-f]+\s+)?"(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z')
RECENT_CLAUDE_S = 15 * 60         # a login/refresh that moved the item is a process this young
RECENT_CLAUDE_MAX = 6


def _etime_s(v: str) -> Optional[int]:
    """`ps` elapsed time ([[dd-]hh:]mm:ss) in seconds, None for anything else."""
    m = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", v)
    if not m:
        return None
    d, h, mi, s = (int(x or 0) for x in m.groups())
    return ((d * 24 + h) * 60 + mi) * 60 + s


def _tier(oauth: dict) -> str:
    """The blob's subscriptionType as three different things: a key that is not there (`absent`), a JSON null (`null` - this daemon's own
    blob carries one) and a value. `str(None)` would print 'None' for the first two, a word that reads like a tier."""
    if "subscriptionType" not in oauth:
        return "absent"
    v = oauth["subscriptionType"]
    return "null" if v is None else str(v)[:24]


def describe_foreign_item(user: str) -> str:
    """Who left a credential the daemon did not write? The item cannot say, but its SHAPE can: this daemon's blob has no refresh
    token, scope ['user:inference'] and an expiry in 2100; a `claude` login/refresh writes a refresh token and an expiry hours away.
    Plus when the item changed and which `claude` processes are young enough to have done it (pid/age/tty, never argv).
    Key NAMES and a few non-secret scalars only - no token, no refresh token, no value of any other field. Best effort: whatever
    cannot be read is said so, and nothing here raises - it annotates a rewrite, it must never stop one."""
    parts: List[str] = []
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", user, "-s", item_service(), "-w"],
                           capture_output=True, text=True, timeout=20, check=False)
        top = json.loads(r.stdout.strip()) if r.returncode == 0 else None
        parts.append(_blob_shape(top))
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError, TypeError):
        parts.append("blob shape unreadable")
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", user, "-s", item_service()],
                           capture_output=True, text=True, timeout=20, check=False)   # no -w/-g: attributes, never the secret
        m = MDAT_RE.search(r.stdout) if r.returncode == 0 else None
        parts.append(f"item modified {m.group(1)}-{m.group(2)}-{m.group(3)}T{m.group(4)}:{m.group(5)}:{m.group(6)}Z" if m
                     else "item mtime unreadable")
    except (OSError, subprocess.SubprocessError):
        parts.append("item mtime unreadable")
    parts.append(_young_claude_note())
    return _cap_line(parts)


def describe_foreign_file() -> str:
    """describe_foreign_item for the credentials file: what the login in it looks like (shape only), when the file was last written, and which
    young `claude` processes could have written it. Best effort, nothing here raises: it annotates a rewrite, it must never stop one."""
    parts: List[str] = []
    # vazio → a file with nothing in it has no shape: "blob shape unreadable" (as is any non-JSON/other-shape content); falhou/ilegível → the same
    # words, from the OSError: the line says it could not look, it never invents a shape
    try:
        parts.append(_blob_shape(json.loads(cred_file().read_bytes().decode("utf-8"))))
    except (OSError, ValueError, AttributeError, TypeError, RecursionError):
        parts.append("blob shape unreadable")
    # vazio → no such answer: a stat gives a time or raises; falhou/ilegível → "file mtime unreadable" (the file went away, or cannot be stat'ed)
    try:
        parts.append(f"file modified {_iso(cred_file().stat().st_mtime)}")
    except OSError:
        parts.append("file mtime unreadable")
    parts.append(_young_claude_note())
    return _cap_line(parts)


def _blob_shape(top) -> str:
    """A credential blob by its key NAMES and a few non-secret scalars - never the token, the refresh token or any other field's value."""
    oauth = top.get("claudeAiOauth") if isinstance(top, dict) else None
    if not isinstance(oauth, dict):
        return "blob shape unreadable"
    exp = _epoch(str(oauth.get("expiresAt")))   # _epoch wants text; an int (ms) or None is what a real blob holds
    scopes = oauth.get("scopes")
    return (f"blob keys={sorted(str(k) for k in oauth)} top={sorted(str(k) for k in top)} "
            f"refreshToken={'yes' if oauth.get('refreshToken') else 'no'} "
            f"expiresAt={_iso(exp) if exp is not None else 'unreadable'} "
            f"scopes={sorted(str(s) for s in scopes) if isinstance(scopes, list) else 'unreadable'} "
            f"subscriptionType={_tier(oauth)}")


def _young_claude_note() -> str:
    """Which `claude` processes are young enough to have written a credential just now (pid/age/tty, never argv)."""
    # vazio → "none" (ps ran and no claude is that young); falhou/ilegível → "process list unreadable": 'ps failed' is not 'no young claude'
    try:
        r = subprocess.run(["ps", "-axo", "pid=,etime=,tty=,comm="], capture_output=True, text=True, timeout=10, check=False)
        if r.returncode != 0:
            raise OSError("ps failed")   # 'ps failed' is not 'no young claude': say which
        young = []
        for ln in r.stdout.splitlines():
            f = ln.split(None, 3)
            age = _etime_s(f[1]) if len(f) == 4 else None
            if age is not None and age <= RECENT_CLAUDE_S and os.path.basename(f[3].strip()) == "claude":
                young.append((age, f[0], f[1], f[2]))
        young.sort()
        return ("young claude processes: " + ("; ".join(f"pid={p} age={e} tty={t}" for _, p, e, t in young[:RECENT_CLAUDE_MAX])
                                              if young else "none") + (f" (+{len(young) - RECENT_CLAUDE_MAX} more)" if len(young) > RECENT_CLAUDE_MAX else ""))
    except (OSError, subprocess.SubprocessError):
        return "process list unreadable"


def _cap_line(parts: List[str]) -> str:
    line, cap, mark = "; ".join(parts), 900, " ...[truncated]"   # a cut line says it was cut: the parts at its tail are the ones that go first
    return line if len(line) <= cap else line[:cap - len(mark)] + mark


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
def operator_off() -> Optional[str]:
    """The operator's kill switches only (the guard asks this one: it must keep working while its own marker is up)."""
    if os.environ.get("GC_POOL_ACCOUNT") == "0":
        return "GC_POOL_ACCOUNT=0"
    c = city()
    if c and (c / ".gc" / "no-pool-account").exists():
        return str(c / ".gc" / "no-pool-account")
    return None


def degraded_marker() -> Optional[Path]:
    """ga-8hcnvb.3: <city>/.gc/pool-account-degraded is written by claude-pool-guard.py when the per-version self-test says the
    installed claude no longer reads the pool item. While it is there the daemon changes nothing and the wrapper (claude-lowprio.sh)
    launches pool sessions on the ambient login. The guard removes it when the self-test passes again."""
    c = city()
    # vazio → None (no marker: the run goes on); falhou/ilegível → Path.exists() raises PermissionError (Python 3.9: anything but "not there"):
    # run_once() calls this before the lock and before any action and main() logs it (ERROR, rc 1), so the run does nothing - never "no marker"
    p = c / ".gc" / DEGRADED_MARKER if c else None
    return p if p is not None and p.exists() else None


def disabled() -> Optional[str]:
    off = operator_off()
    if off:
        return off
    m = degraded_marker()
    return f"{m} (claude-pool-guard: the per-version self-test failed)" if m else None


def write_heartbeat() -> None:
    """One line saying 'a run finished CLEAN at <epoch>': it got to the end and logged no ERROR (a refused Keychain write, a read-back that
    does not match, an unpublished decision). A run that decides nothing because there is nothing to decide - every account allowed,
    or no key in the vault - is clean. The exit status cannot say any of this: a run that found no accounts library exits 0 too.
    claude-pool-guard.py reads this file: no clean run for 10 min = the daemon is not doing its job."""
    if ERRORS_THIS_RUN:
        return
    c = city()
    if not c or not (c / ".gc").is_dir():
        return
    p = c / ".gc" / HEARTBEAT_FILE
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    try:
        tmp.write_text(json.dumps({"epoch": now(), "updated": _iso(now()), "pid": os.getpid()}) + "\n")
        os.replace(tmp, p)
    except OSError as e:
        log("WARN", f"heartbeat not written ({type(e).__name__})")


def order_of_use(lib) -> List[str]:
    """The e-mails in the order of use ([] = the usage store gave no order: nothing to rank, so nothing to do)."""
    try:
        order = lib.ordem_das_contas()
        return [e for e in order if isinstance(e, str) and e]
    except Exception as e:  # noqa: BLE001
        log("WARN", f"ordem_das_contas failed ({type(e).__name__}) - nothing to do")
        return []


NO_ROW = "the usage store has no row for it (or could not be read)"


def usage_readings(lib, t: float) -> Dict[str, Tuple[Optional[float], str]]:
    """email -> (epoch at which the usage store's numbers for that account were REAL, "")  or  (None, why there is no such time).

    The order of use (e-mails only) cannot say how old the readings behind it are, and the collector that writes them runs
    every ~30 min. `last_ok_at` is the time the numbers were real: on a good read it equals `collected_at`, and a failed read
    carries the old numbers forward flagged `stale` / ok=false with the OLD last_ok_at (lib/claude_usage_collector.py). The
    library bands those readings 'unknown' whatever they say, so they are no reading here either. A time with no zone, or one
    that is still ahead of the clock, is not a time we can compare: unknown. An account missing from the dict has no row.

    Read this BEFORE asking the library for the order: a collection that lands in between can only make the order newer than
    this evidence, never older, so the mistake that remains is the cautious one (an entry waits one more run)."""
    try:
        accts = json.loads(Path(lib.USAGE_STORE).read_text()).get("accounts") or []
    except (AttributeError, TypeError, OSError, ValueError, RecursionError):   # no USAGE_STORE on the library, unreadable, not JSON / too deep, not an object
        return {}
    out: Dict[str, Tuple[Optional[float], str]] = {}
    for c in accts:
        if not isinstance(c, dict) or not isinstance(c.get("email"), str) or not c["email"]:
            continue
        email = c["email"]
        if c.get("stale") or c.get("ok") is False:
            out[email] = (None, "its last collection failed (the reading is carried over from an older one)")
            continue
        raw = c.get("last_ok_at")
        try:
            dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            at = _sane_epoch(dt.timestamp()) if dt.tzinfo is not None else None
        except (AttributeError, ValueError, OverflowError, OSError):   # not a string, not ISO-8601, out of range
            at = None
        if at is None:
            out[email] = (None, "its reading has no usable last_ok_at")
        elif at > t + CLOCK_SKEW_S:
            out[email] = (None, f"its reading is stamped {_iso(at)}, ahead of the clock")
        else:
            out[email] = (at, "")
    return out


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
    # The same credential on the path a session takes when it cannot read the item (ga-6gat1o). A switch that reaches only the item moves
    # nothing for such a session, so it is not a switch: the decision stays where it was, and the next run heals the item and tries again.
    if not put_cred_file(token):
        log("ERROR", f"credentials file not switched to {email} - decision NOT changed")
        return False
    prev = st.get("current")
    st.update(current=email, fingerprint=fingerprint(token), since=t, reason=reason, previous=prev)
    log("INFO", f"SWITCH {prev or '-'} -> {email} fp={fingerprint(token)}: {reason}")
    if st.get("exhausted", {}).pop(email, None) is not None:
        log("INFO", f"exhausted entry for {email} dropped: it is the pool's account now")
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
    """The daemon is the single writer: if the item or the credentials file is gone or holds another account than the decision, put it back."""
    kind, held = read_item_token(user)
    item_ok = True
    if kind == "unknown":
        log("WARN", "pool item unreadable (locked keychain?) - not touched")
        item_ok = False
    elif not (kind == "ok" and held == token):
        log("WARN", f"pool item {'missing' if kind == 'missing' else 'holds fp=' + fingerprint(held or '')} but the decision is "
                    f"{email} fp={fingerprint(token)} - rewriting")
        if kind == "ok":   # a credential somebody else wrote: say what it looks like BEFORE the rewrite erases the evidence (ga-xknkke)
            log("WARN", f"foreign write to the pool item (fp={fingerprint(held or '')}): {describe_foreign_item(user)}")
        item_ok = write_item(user, token)
    # The file is looked at whatever became of the item: an item that cannot be read (locked Keychain) is the very case in which a session reads the file.
    heal_cred_file(token, email)
    if not item_ok:
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


def drop_entry(ex: dict, email: str, why: str) -> None:
    """The only way an entry leaves the exhausted registry once it is expired: with a line that says why."""
    ex.pop(email, None)
    log("INFO", f"exhausted entry for {email} dropped: {why}")


def failback(st: dict, keys: Keys, order: List[str], readings: Dict[str, Tuple[Optional[float], str]], user: str, cur: str, t: float) -> None:
    """The active account answers. Go back to an account WE saw rate-limited ('rejected') whose stored reset time has passed -
    but only on evidence of three things, and each of them can be 'could not tell':

      1. it renewed        - the stored reset time has passed (no probe: Mayor 04/10; if it has not, its 429 sends us back);
      2. where it ranks    - the order of use says it comes before the active account; and that order is only worth what its
                             reading is worth, so the account needs a good usage reading taken AFTER its reset (usage_readings).
                             A reading from before the reset, a failed collection, no row: the state AFTER the reset is not
                             known, so the entry is KEPT, the log says what it waits for, and the next run asks again;
      3. its key           - the vault gave it back this run (it is asked only for accounts that could be switched to).

    An entry is dropped only when something is KNOWN against it, and each drop says what: a refused key (401/403) is not a limit
    that renews (an unprobed failback would put a still-refused key in the item); an entry that does not say why it was
    registered ('we do not know why' must not read as 'it was a limit that renews'); a fresh reading that ranks it after the
    active account; a better ranked recovered account that took the pool. Everything not decided stays in the registry."""
    ex = st.get("exhausted")
    if not isinstance(ex, dict):
        return
    cur_pos = order.index(cur) if cur in order else len(order)   # an account missing from the order is ranked last (INFO in current_credential)
    ready: List[str] = []
    for e in [e for e, v in ex.items() if v.get("reset_epoch", math.inf) <= t]:
        why, reset = ex[e].get("why"), ex[e]["reset_epoch"]
        if why == "invalid":
            drop_entry(ex, e, "its key was refused (401/403), which is not a limit that renews - it is probed the normal way if a later failover reaches it")
        elif why != "rejected":
            log("WARN", f"state: exhausted entry for {e} does not say why it was registered - not failed back to")
            drop_entry(ex, e, "it does not say why it was registered - it is probed the normal way if a later failover reaches it")
        else:
            at, why_not = readings.get(e, (None, NO_ROW))
            if at is None or at <= reset:
                log("INFO", f"waiting for a usage collection of {e} taken after its reset ({_iso(reset)}) before deciding whether to go "
                            f"back to it: {why_not or 'the last good reading is from ' + _iso(at)}. Entry kept")
            elif e not in order:
                log("WARN", f"cannot tell where {e} ranks: it has a reading but is not in the order of use this run. Entry kept")
            elif order.index(e) >= cur_pos:
                drop_entry(ex, e, f"the usage collected {_iso(at)}, after its reset ({_iso(reset)}), ranks it behind {cur}, which is in use")
            else:
                ready.append(e)
    ready.sort(key=order.index)
    for i, e in enumerate(ready):
        key = keys.token(e)
        if not key:
            log("WARN", f"failback to {e} not done: its key did not come from the vault this run - entry kept for the next run")
            continue
        if switch_to(st, user, e, key, f"failback: {e} passed its stored reset time and the usage collected after it ranks it ahead of {cur}", t):
            for lower in ready[i + 1:]:
                drop_entry(ex, lower, f"recovered, but ranks behind {e}, which took the pool - it is probed the normal way if a later failover reaches it")
        else:
            # The write failed, so the failback did NOT happen. A write that is refused is refused for the next account too:
            # stop here, and every recovered account not tried (this one included) stays in the registry for the next run.
            log("WARN", f"failback to {e} not done (the pool item could not be switched) - entry kept, and so are the {len(ready) - i - 1} not tried")
        break


def decide(st: dict, keys: Keys, order: List[str], readings: Dict[str, Tuple[Optional[float], str]], user: str, t: float) -> None:
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
        if ex.pop(cur, None) is not None:
            log("INFO", f"exhausted entry for {cur} dropped: it answered the probe, which beats what was stored about it")
        failback(st, keys, order, readings, user, cur, t)
    now_cur = st.get("current")
    if kind == "item" and now_cur == cur:
        # the key of the decision never came from the vault and the item IS that key: nothing to heal the ITEM against - but that key is the
        # decision's credential (the fingerprint says so), and the credentials file is healed against it
        heal_cred_file(tok, cur)
        return
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
    readings = usage_readings(lib, now())   # BEFORE the order - see usage_readings
    order = order_of_use(lib)
    if not order:
        log("WARN", "no account in the order of use (usage store unreadable or empty) - nothing changed")
        return 0
    st = load_state()
    if st is None:
        return 1
    before = json.dumps(st, sort_keys=True)
    moved_from = (st.get("current"), st.get("fingerprint"))
    decide(st, Keys(lib), order, readings, user, now())
    if json.dumps(st, sort_keys=True) != before:
        try:
            publish_state(st)
        except Exception as e:  # noqa: BLE001 - OSError (full disk, a read-only state dir) is the realistic one; the TYPE only
            # decide() has already run, so the pool item may already hold the new account while the published decision (what the
            # WhatsApp services read) still names the old one. Say which of the two happened: only a run that moved the decision
            # (switch_to sets current + fingerprint together with the write) left the item and the file disagreeing.
            if (st.get("current"), st.get("fingerprint")) != moved_from:
                log("ERROR", f"decision NOT published ({type(e).__name__}) but the pool item was switched to {st.get('current')} "
                             f"fp={st.get('fingerprint')}; the decision file and the item disagree until a run publishes")
            else:
                log("ERROR", f"decision NOT published ({type(e).__name__}); this run did not move the pool item to another account")
            return 1
    write_heartbeat()   # only a run that got here and logged no ERROR: not a disabled one, not one that found no library/order/state to work with
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
