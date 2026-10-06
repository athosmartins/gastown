#!/usr/bin/env python3
"""claude-pool-account — which Claude account the headless pool runs on, as DATA (ga-8hcnvb.1), moved at 100% by a script
that spends no credit (ga-8hcnvb.2).

The pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner) is launched through
claude-lowprio.sh, which points each session at a Keychain item (CLAUDE_SECURESTORAGE_CONFIG_DIR). claude
re-reads that item every ~30 s, so rewriting it moves every LIVE pool session to another account with no restart
and no lost conversation (measured, ga-2yyitx). This script is the SINGLE WRITER of that item and of the decision
the WhatsApp services read (`current` in CLAUDE_POOL_STATE).

THE POOL MOVES ONLY WHEN THE LIMIT IS REALLY HIT (Athos 04/10: "tem que trocar no 100%. A gente não quer ficar com 5% sem
usar"). No utilization threshold, no agent, no `claude`, and no call that is paid for on the way: a REJECTED 429 costs
nothing, a call that is served costs tokens (and may open an idle 5h window), so the API is asked only when something has
already said the limit was hit. What says so is the pool's own sessions: a pool pane showing claude's limit screen - the modal
("What do you want to do?" / "Stop and wait for limit to reset"), which claude opens on a session's FIRST hit, or the envelope
"⎿ You've hit your weekly limit · resets ..." as the last turn on screen, which is all a session shows on every later hit
(measured). That is EVIDENCE; with none, the API is not called at all.

One run (launchd StartInterval, single instance via flock):
  * no usable decision yet            -> seed with the first account of the order whose key is valid (see below).
  * no pool session shows the limit   -> nothing is asked of the API. The decision does not change (failback aside).
  * a pool session shows the limit    -> the active account is asked ONCE for its reply (a call that is rejected is free; the
    (new evidence, see track_panes)      anthropic-ratelimit-unified-* headers carry the reset time we store). REJECTED (or its key
                                         refused) -> failover to the first account of the order that is not known-exhausted and
                                         whose KEY is valid. ANSWERS -> the screen was not about this account: nothing moves, and
                                         the account is not asked again for EVIDENCE_COOLDOWN_S (the one case that can cost a
                                         few tokens, bounded). Could not tell -> nothing changes (error != exhausted).
  * a failover that lands on an account that is ALSO exhausted is not looked for: its sessions hit the limit, the modal shows
    again, and this same run-through reruns by itself (ga-8hcnvb.2 (d)). The candidate is not probed for balance first.
  * Failback only to an account that WE saw exhausted (rate-limited, not key-refused), whose stored reset time has passed,
    whose usage reading in the usage store was taken AFTER that reset, and which that fresh reading ranks ahead of the
    active one — with NO probe of it (Mayor 04/10: no balance probe on the way back; if it has not really renewed, its
    429 simply triggers the failover again).
  * UNSTICK: a session that was sitting on the limit modal when the pool moved stays there (the modal does not notice a new
    credential by itself - measured, ga-2yyitx). Once the item has been rewritten for SETTLE_S (claude re-reads it every
    ~30 s) the daemon sends that pane ONE Escape. This is a scoped exception to the send-keys doctrine: see docs/claude-pool-account.md
    ("The Escape exception") for its guards - pool panes only (proven by the wrapper's POOL-ACCT SET line for a live process),
    the modal re-read from the screen immediately before sending, never Mayor or a crew.
  * the active account could not be asked (network, 5xx, anything not 2xx/429/401/403) -> no failover and no failback: the
    DECISION does not change. Error != exhausted. (The run still goes on to heal_item, which may put the item back to the
    decision already taken - the item following the decision, not the probe changing it.)

The order of use comes from the usage store, which the collector rewrites every ~30 min while this daemon runs every
minute: at the reset tick the order can be half an hour old, and a reading taken BEFORE the reset says nothing about the
account AFTER it ("not known" is not "does not outrank"). So an expired entry is never judged by the order alone:
  * no good reading of that account taken after its reset -> the entry is KEPT and the log says it is waiting for the
    next collection; the next run asks again;
  * a good reading taken after the reset                  -> the order decides: fail back if the account ranks ahead
    of the active one, otherwise drop the entry - with a log line saying why.
Every removal of an entry from the registry has a log line with its reason; nothing leaves it silently.

The switch path never starts `claude` (it may be the thing that is exhausted): the evidence probe is one tiny haiku HTTP
call, and the answer is read from the anthropic-ratelimit-unified-* headers; a candidate's key is checked with the
count_tokens endpoint, which validates the key and is never billed (it says nothing about limits, so a candidate that turns out
to be exhausted too is found the way the first one was). Neither follows a redirect (the Bearer would travel with it): a
30x is "could not tell".

Tokens: read from the vault by lib/claude_account_pool.token_da_conta, held in memory, sent only as the Bearer of
the probe and as the hex of a `security -i` command on STDIN. They are never in argv, env, log, state or output;
accounts are named by e-mail + sha256[:8] fingerprint.

The vault is read LAZILY (Keys): the key of the CURRENT account every run, the keys of the candidates only when the pool
has to move (seed, failover, failback). `token_da_conta` returns None both for "no key registered" and for "vault
unreadable just now", so a None for the current account is NOT "its key is gone": the Keychain item this daemon wrote
(and the fingerprint in the state) is the second witness. Item holds the decision's credential -> keep the decision and
probe THAT token; item cannot be read -> change nothing; item missing or holding something else -> choose again.

KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the run does nothing at all.
       GC_POOL_UNSTICK=0 or <city>/.gc/no-pool-unstick   -> the run still decides and switches, but never sends a key to a pane.
SEAMS (tests): CLAUDE_POOL_STATE, CLAUDE_POOL_CRED_DIR (GC_POOL_CRED_DIR, the wrapper's name for it, is honoured too),
CLAUDE_POOL_ACCOUNTS_LIB, CLAUDE_POOL_NOW, CLAUDE_POOL_TMUX (the tmux binary), CLAUDE_POOL_TMUX_SOCKET (default "gascity"),
CLAUDE_POOL_EVIDENCE_COOLDOWN_S,
CLAUDE_POOL_PROBE_URL (honoured ONLY for a loopback host — an env var must not be able to aim a token elsewhere).
"""
from __future__ import annotations

import calendar
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
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

PROBE_URL = "https://api.anthropic.com/v1/messages"
PROBE_MODEL = "claude-haiku-4-5-20251001"
PROBE_TIMEOUT_S = 10
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
# ga-8hcnvb.2 - evidence of the limit, and the Escape that unsticks a session sitting on it
DEFAULT_TMUX_SOCKET = "gascity"   # the city's tmux server (`tmux -L gascity`): every gc session, pool or not, lives in it
SETTLE_S = 45                     # claude re-reads the pool item every ~30 s: no Escape until the item has been this long in place
STALE_WINDOW_S = 90               # a limit modal first SEEN this soon after a rewrite belongs to the credential that was replaced
MAX_ESC_TRIES = 3                 # per pane: an Escape that does not take is not repeated for ever
MAX_ESC_PER_RUN = 20              # and never an unbounded burst of keys
EVIDENCE_COOLDOWN_S = 600         # evidence whose probe found the account ANSWERING does not buy another probe of it for this long
LAUNCH_TAIL_BYTES = 1 << 20       # how much of the end of the wrapper's log is read to find pool launches
START_SLACK_S = 2                 # a process started at most this much AFTER its POOL-ACCT SET line is not the process that wrote it
START_MAX_AGE_S = 120             # ... and one that started much BEFORE it cannot be the wrapper that exec'd into claude then
SET_RE = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) pid=(\d+) agent=(\S*) wrapper POOL-ACCT SET item=(Claude Code-credentials-[0-9a-f]{8})")
PS_RE = re.compile(r"\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s*$")
PANE_ID_RE = re.compile(r"%\d+")
SOCKET_RE = re.compile(r"[A-Za-z0-9_.-]{1,64}")
AGENT_RE = re.compile(r"[A-Za-z0-9._@:-]{1,80}")
NEVER_RE = re.compile(r"mayor|crew", re.I)   # Mayor's and the crews' Remote Control is never touched (Athos 05/10): not looked at, whatever else says they follow the item


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
    """verdict: allowed | rejected | invalid | unknown (| valid, from validate_key: the key is accepted, nothing is said about
    limits).  `unknown` means 'could not tell': it never triggers a failover or a
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


def _send(url: str, token: str, body: dict) -> Tuple[Optional[int], Dict[str, str], str]:
    """(status, headers, "") for any HTTP answer - a 4xx/5xx still carries the headers we need - and (None, {}, why) when there was
    none. A redirect is not an answer about the account, whatever headers it carries, and following it would send the Bearer along."""
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": "Bearer " + token, "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20", "content-type": "application/json",
        "user-agent": "claude-pool-account/1"})
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=PROBE_TIMEOUT_S) as r:
            return r.status, dict(r.headers.items()), ""
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            return None, {}, f"redirect http={e.code} (not followed)"
        return e.code, dict(e.headers.items()) if e.headers else {}, ""
    except Exception as e:  # noqa: BLE001 - network down, DNS, TLS, timeout: could not tell
        return None, {}, f"{type(e).__name__}"


def probe(token: str) -> Probe:
    """The reply of the account to ONE 1-token haiku call. Used only AFTER evidence that the limit was hit (a pool pane on the
    limit modal): a rejected call costs nothing and its headers carry the reset time; a served one costs a few tokens, which is
    why nothing calls this on the healthy path. Every call leaves an "API-CALL messages" line, so 'it spent nothing' can be read off the log."""
    log("INFO", f"API-CALL messages (1-token haiku) with the key fp={fingerprint(token)}")
    st, headers, why = _send(probe_url(), token, {"model": PROBE_MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "."}]})
    return Probe("unknown", None, "", why) if st is None else classify(st, headers, now())


def count_tokens_url() -> str:
    return probe_url().rstrip("/") + "/count_tokens"


def validate_key(token: str) -> Probe:
    """Is this KEY accepted? count_tokens answers 2xx for a valid key and 401/403 for a refused one, never serves a generation (it is
    not billed) and carries no limit headers - so it says nothing about whether the account has balance. That is the point: it is
    what a CANDIDATE gets before the item is written, because a call that would tell (a served one) costs tokens on every candidate.
    verdict: valid | invalid | unknown (anything else, a 429 included: there is no limit to read here)."""
    log("INFO", f"API-CALL count_tokens (not billed) with the key fp={fingerprint(token)}")
    st, _h, why = _send(count_tokens_url(), token, {"model": PROBE_MODEL, "messages": [{"role": "user", "content": "."}]})
    if st is None:
        return Probe("unknown", None, "", why)
    if st in (401, 403):
        return Probe("invalid", now() + INVALID_KEY_COOLDOWN_S, "", f"http={st}")
    if 200 <= st < 300:
        return Probe("valid", None, "", f"http={st}")
    return Probe("unknown", None, "", f"http={st}")


# ── the Keychain item ──────────────────────────────────────────────────────────────────────────────
def write_item(user: str, token: str) -> bool:
    """Rewrite the pool item. The secret travels only on `security -i`'s STDIN (hex data): never in argv."""
    if not valid_user(user):   # run_once checks this first; here too because this is where the command line is built
        log("ERROR", "refusing to build a security command for an account name that is not a plain login name")
        return False
    if not POOL_ITEM_RE.fullmatch(item_service()):   # the writer is where a wrong item would do damage: never Mayor's/crews' default one
        log("ERROR", "refusing to write a Keychain item that is not the pool's hashed one")
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


# ── evidence: the pool's own panes (ga-8hcnvb.2) ────────────────────────────────────────────────────
# What says "the limit was hit" is a pool session sitting on claude's limit modal. Measured on claude 2.1.291 with a really
# exhausted account (a rejected call is free), the screen is, at the bottom of the pane and in place of the prompt:
#
#     What do you want to do?
#     ❯ 1. Stop and wait for limit to reset
#       2. Wait here, then continue automatically at Oct 7 at 7pm
#       3. Upgrade your plan
#     Enter to confirm · Esc to cancel
#
# It stays until a key is pressed (identical 20 s later). Above it sits the envelope of the turn that hit the limit, and after Esc
# the prompt is back with that envelope still above it:
#
#     ❯ Reply with exactly: ALPHA
#       ⎿  You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)
#     ✻ Sautéed for 3s · done 7:35 AM
#
# The modal opens on a session's FIRST hit only (measured, 2.1.291): once it was dismissed, every later hit - 150 s later too - is just
# that envelope (plus "/upgrade to increase your usage limit.") with the prompt right under it, nothing blocking. So a pane is on the
# limit screen when the modal is up, or when the envelope is the LAST turn on screen (limit_hit); the envelope of an older turn, with
# anything after it, is history. Each hit has a signature (its prompt + envelope + summary), so a new hit is a new sighting; the
# modal and the envelope of the same hit have the same signature. Escape is for the modal alone: the envelope blocks nothing.
class PanePeek:
    def __init__(self, pane_id: str, pane_pid: int, proof_pid: int, agent: str, stuck: bool, launched: float, hit: Optional[str] = None):
        self.pane_id, self.pane_pid, self.proof_pid, self.agent, self.stuck = pane_id, pane_pid, proof_pid, agent, stuck
        self.hit = hit if hit is not None else ("modal" if stuck else None)   # signature of the limit screen on it, None = not on one
        self.launched = launched   # when the wrapper started the claude in it (the POOL-ACCT SET line): a session started after a rewrite never had the old credential
        self.key = f"{pane_id}:{proof_pid}"   # a recycled pane id with another process is another key


class Scan:
    """`ok` False = could not look (no tmux, no ps): nothing is concluded from it, and the bookkeeping about panes is left as it was."""

    def __init__(self, ok: bool, panes: Optional[List[PanePeek]] = None):
        self.ok, self.panes = ok, panes or []
        self.by_key = {p.key: p for p in self.panes}


def modal_stuck(text: str) -> bool:
    """True iff the screen's LAST lines are claude's limit modal. The footer must be the last line on screen and the question and the
    option must precede it, in that order: while the modal is open it replaces the prompt box, so nothing follows it. An agent that
    merely QUOTES these words in its transcript (this very bead does) has the prompt box under the quote, and is not matched -
    sending Escape to a working session interrupts it."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines or not ("Enter to confirm" in lines[-1] and "Esc to cancel" in lines[-1]):
        return False
    tail = lines[-10:-1]
    ask = [i for i, ln in enumerate(tail) if "What do you want to do?" in ln]
    opt = [i for i, ln in enumerate(tail) if re.search(r"\b1\.\s*Stop and wait for limit to reset", ln)]
    return bool(ask and opt and ask[-1] < opt[-1])


LIMIT_LINE_RE = re.compile(r"^⎿\s+You[\u2019']ve hit your\b.{0,80}?\blimit\b")
SEP_RE = re.compile(r"^[─━═▔▁_\-—]{8,}$")
HIT_WINDOW = 24   # the envelope must be among the last lines on screen; further up it is history


def limit_hit(text: str, modal: bool) -> Optional[str]:
    """The signature of the limit screen on this pane, or None when the pane is not on one. `modal` says the modal is up (the caller
    ran modal_stuck): the modal block is then cut off and the hit that opened it is read from what is above. Otherwise the pane is on
    the limit screen iff the LAST envelope "⎿ You've hit your ... limit" has no later turn under it: no assistant line (⏺), no tool
    result (⎿), no running turn ("esc to interrupt"), no further user prompt - the prompt box (a prompt line right under a rule) is
    not one, whatever the user has half-typed in it. The signature hashes the hit's prompt, envelope and summary line."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if modal:
        ask = [i for i, ln in enumerate(lines) if "What do you want to do?" in ln]
        if not ask:
            return "modal"
        lines = lines[:ask[-1]]
        while lines and SEP_RE.match(lines[-1]):
            lines.pop()
    hits = [i for i, ln in enumerate(lines) if LIMIT_LINE_RE.match(ln)]
    if not hits or hits[-1] < len(lines) - HIT_WINDOW:
        return "modal" if modal else None
    at = hits[-1]
    for j in range(at + 1, len(lines)):
        ln = lines[j]
        if ln.startswith(("⏺", "⎿")) or "esc to interrupt" in ln:
            return "modal" if modal else None
        if ln.startswith("❯") and ln[1:].strip() and not SEP_RE.match(lines[j - 1]):
            return "modal" if modal else None
    start = at - 1 if at > 0 and lines[at - 1].startswith("❯") else at
    stop = at + 1
    while stop < len(lines) and not SEP_RE.match(lines[stop]):
        stop += 1
    return hashlib.sha1("\n".join(lines[start:stop]).encode("utf-8")).hexdigest()[:12]


def tmux_bin() -> Optional[str]:
    p = os.environ.get("CLAUDE_POOL_TMUX")
    if p:
        return p if os.access(p, os.X_OK) else None
    return shutil.which("tmux") or next((c for c in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.access(c, os.X_OK)), None)


def tmux_socket() -> str:
    s = os.environ.get("CLAUDE_POOL_TMUX_SOCKET") or DEFAULT_TMUX_SOCKET
    return s if SOCKET_RE.fullmatch(s) and s not in (".", "..") else DEFAULT_TMUX_SOCKET


def tmux(args: List[str]) -> Tuple[Optional[int], str]:
    """(exit code, stdout); (None, "") when tmux could not be run at all."""
    b = tmux_bin()
    if not b:
        return None, ""
    try:
        r = subprocess.run([b, "-L", tmux_socket()] + args, capture_output=True, text=True, errors="replace", timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return r.returncode, r.stdout


def process_table() -> Optional[Dict[int, Tuple[int, float]]]:
    """pid -> (ppid, start time as epoch). One `ps` for the whole table; None when it could not be read."""
    try:
        r = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart="], env={"LC_ALL": "C", "PATH": "/bin:/usr/bin"},
                           capture_output=True, text=True, errors="replace", timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    table: Dict[int, Tuple[int, float]] = {}
    for line in r.stdout.splitlines():
        m = PS_RE.match(line)
        if not m:
            continue
        try:
            table[int(m.group(1))] = (int(m.group(2)), time.mktime(time.strptime(" ".join(m.group(3).split()), "%a %b %d %H:%M:%S %Y")))
        except (ValueError, OverflowError):
            continue
    return table


def pool_launches() -> Optional[Dict[int, Tuple[float, str]]]:
    """pid -> (epoch of the line, agent) for every launch the WRAPPER logged as following THIS pool item ("POOL-ACCT SET"), read from
    the end of the wrapper's log. A session launched while there was no item (SKIP) or with the variable already set (KEEP) is
    not in it: it does not follow the item, so neither a switch nor an Escape is any business of ours.
    {} = nothing follows the item (no log yet is exactly that); None = the log is there and could not be READ: could not look."""
    c = city()
    if not c:
        return {}
    p = c / ".gc" / "logs" / "claude-pool-account.log"
    try:
        with open(p, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - LAUNCH_TAIL_BYTES))
            raw = f.read()
    except FileNotFoundError:
        return {}
    except OSError:
        return None
    want = item_service()
    out: Dict[int, Tuple[float, str]] = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        m = SET_RE.fullmatch(line.strip())
        if not m or m.group(4) != want:
            continue
        try:
            at = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ"))
        except (ValueError, OverflowError):
            continue
        if NEVER_RE.search(m.group(3)):   # judged on what the line SAYS, before it is tidied: a name that would not pass AGENT_RE is no way in
            continue
        agent = m.group(3) if AGENT_RE.fullmatch(m.group(3)) else "?"
        out[int(m.group(2))] = (float(at), agent)
    return out


def scan_panes() -> Scan:
    """Which pool panes are on the limit screen right now (the modal, or the envelope as the last turn). A pane counts only if a process that the wrapper launched onto the pool item
    is alive in it (the pane's own process or a descendant): the pid in the SET line is the claude pid (the wrapper exec's), and a
    pid can be recycled, so the process must also have STARTED when the line says it did."""
    launches = pool_launches()
    if launches is None:
        log("WARN", "the wrapper's log could not be read - no pane looked at this run")
        return Scan(False)
    if not launches:
        return Scan(True)   # nothing follows the item: no pane to look at, so tmux is not even asked
    table = process_table()
    if table is None:
        log("WARN", "ps unreadable - no pane looked at this run")
        return Scan(False)
    proven: Dict[int, Tuple[str, float]] = {}
    for pid, (at, agent) in launches.items():
        row = table.get(pid)
        if NEVER_RE.search(agent):
            continue
        if row is not None and row[1] <= at + START_SLACK_S and at - row[1] <= START_MAX_AGE_S:
            proven[pid] = (agent, at)
    if not proven:
        return Scan(True)
    rc, out = tmux(["list-panes", "-a", "-F", "#{pane_id} #{pane_pid} #{pane_dead}"])
    if rc is None:
        log("WARN", "tmux could not be run - no pane looked at this run")
        return Scan(False)
    if rc != 0:
        return Scan(False)   # no server / a failure: nothing can be concluded, and nothing is dropped from what was seen before
    pane_of: Dict[int, Tuple[str, int]] = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and PANE_ID_RE.fullmatch(f[0]) and f[1].isdigit() and f[2] == "0":
            pane_of[int(f[1])] = (f[0], int(f[1]))
    panes: List[PanePeek] = []
    for pid, (agent, launched) in sorted(proven.items()):
        cur, hops = pid, 0
        while cur in table and hops < 8 and cur not in pane_of:   # the pane's process is the claude itself, or an ancestor of it
            cur, hops = table[cur][0], hops + 1
        if cur not in pane_of:
            continue
        pane_id, pane_pid = pane_of[cur]
        rc, text = tmux(["capture-pane", "-p", "-J", "-t", pane_id])
        if rc != 0:
            continue
        stuck = modal_stuck(text)
        panes.append(PanePeek(pane_id, pane_pid, pid, agent, stuck, launched, limit_hit(text, stuck)))
    return Scan(True, panes)


def safe_scan() -> Scan:
    try:
        return scan_panes()
    except Exception as e:  # noqa: BLE001 - could not look is a state of its own, and it concludes nothing
        log("WARN", f"pane scan failed ({type(e).__name__}) - no pane looked at this run")
        return Scan(False)


def evidence_cooldown_s() -> float:
    try:
        v = float(os.environ.get("CLAUDE_POOL_EVIDENCE_COOLDOWN_S", ""))
    except ValueError:
        return EVIDENCE_COOLDOWN_S
    return v if math.isfinite(v) and 0 <= v <= 86400 else EVIDENCE_COOLDOWN_S


def unstick_disabled() -> Optional[str]:
    if os.environ.get("GC_POOL_UNSTICK") == "0":
        return "GC_POOL_UNSTICK=0"
    c = city()
    if c and (c / ".gc" / "no-pool-unstick").exists():
        return str(c / ".gc" / "no-pool-unstick")
    return None


def send_escape(p: PanePeek) -> bool:
    """The ONE key this daemon ever sends, to a pane it has proven to be a pool session on the limit modal. The scan is some
    seconds old, so look again right before: same process in the pane, and the modal still the last thing on its screen."""
    rc, out = tmux(["display-message", "-p", "-t", p.pane_id, "#{pane_pid}"])
    if rc != 0 or out.strip() != str(p.pane_pid):
        log("INFO", f"pane {p.pane_id} ({p.agent}) is not the process it was a moment ago - nothing sent")
        return False
    rc, text = tmux(["capture-pane", "-p", "-J", "-t", p.pane_id])
    if rc != 0 or not modal_stuck(text):
        log("INFO", f"pane {p.pane_id} ({p.agent}) no longer shows the limit modal - nothing sent")
        return False
    rc, _ = tmux(["send-keys", "-t", p.pane_id, "Escape"])
    if rc != 0:
        log("WARN", f"pane {p.pane_id} ({p.agent}): tmux send-keys failed (exit={rc})")
        return False
    return True


def track_panes(st: dict, scan: Scan, t: float) -> None:
    """st["panes"] = {pane key: {"first": when this hit was first seen, "tries": Escapes spent on it, "sig": the hit's signature,
    "modal": whether the modal is up}} for the panes that are on the limit screen NOW. A pane that is not on it (any more), or not in
    the scan at all, is forgotten; one on ANOTHER hit than the one tracked is a new sighting (first, tries, and the answer to an
    earlier probe all start over: a new screen is new evidence). The modal and the envelope of the same hit share a signature, so
    dismissing the modal does not make the same hit look new. A scan that could not look changes nothing: 'could not tell' is not
    'nobody is stuck any more'."""
    if not scan.ok:
        return
    tracked = st.setdefault("panes", {})
    for k in list(tracked):
        p = scan.by_key.get(k)
        if p is None or p.hit is None:
            del tracked[k]
    for p in scan.panes:
        if p.hit is None:
            continue
        e = tracked.get(p.key)
        if e is None or e.get("sig") != p.hit:
            e = tracked[p.key] = {"first": t, "tries": 0, "sig": p.hit}
        e["modal"] = p.stuck
    if not tracked:
        del st["panes"]


def stale_modal(st: dict, p: PanePeek, entry: dict) -> bool:
    """Is this limit screen about a credential that has since been REPLACED? True when the pool item was rewritten and the session either
    was started before the rewrite AND was first seen on the modal no later than STALE_WINDOW_S after it (claude re-reads the item
    only every ~30 s, so a hit that lands just after the rewrite is still the old credential's). Such a modal tells nothing about the
    account in use now - it is no evidence, and it is what the Escape is for. A session started AFTER the rewrite never had the old
    credential, and one first seen on the modal later than the window is on the new one: both are evidence."""
    at = _sane_epoch(st.get("item_at"))
    if at is None:
        return False
    return p.launched <= at and entry["first"] <= at + STALE_WINDOW_S


def fresh_evidence(st: dict, scan: Scan) -> List[PanePeek]:
    tracked = st.get("panes", {})
    return [p for p in scan.panes if p.hit is not None and p.key in tracked and not stale_modal(st, p, tracked[p.key])]


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
    # ga-8hcnvb.2 bookkeeping. Dropping it is always the cautious answer: a pane forgotten is looked at again as a new sighting (one more
    # probe at worst), a mark forgotten is the same. Neither can move the pool or press a key by itself - except `tries`, whose garbled
    # reading is 'already tried', so that junk can never buy a fresh set of Escapes.
    if "panes" in st:
        pn = st["panes"]
        if not isinstance(pn, dict):
            log("WARN", "state: `panes` is not an object - dropped")
            del st["panes"]
        else:
            for k in list(pn):
                e = pn[k]
                first = _sane_epoch(e.get("first")) if isinstance(e, dict) else None
                if first is None or first > t + CLOCK_SKEW_S:   # not a time, or a sighting that has not happened yet
                    del pn[k]
                    continue
                tr = e.get("tries")
                if isinstance(tr, bool) or not isinstance(tr, int) or tr < 0:
                    e["tries"] = MAX_ESC_TRIES
                if "asked" in e:
                    asked = _sane_epoch(e["asked"])
                    if asked is None or asked > t + CLOCK_SKEW_S:
                        del e["asked"]
                if "sig" in e and not isinstance(e["sig"], str):
                    del e["sig"]   # a hit forgotten is a new sighting
                if "modal" in e and not isinstance(e["modal"], bool):
                    del e["modal"]
    if "item_at" in st:
        at = _sane_epoch(st["item_at"])
        if at is None or at > t + CLOCK_SKEW_S:   # a rewrite that has not happened yet is no rewrite (the clock went back, or junk)
            log("WARN", "state: `item_at` is not a past time - dropped (no rewrite is known, so nothing is unstuck until the next one)")
            del st["item_at"]
    st.pop("evidence_probe", None)   # an earlier shape of this bookkeeping (per account); the marks live on the panes now
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
    prev = st.get("current")
    st.update(current=email, fingerprint=fingerprint(token), since=t, reason=reason, previous=prev, item_at=t)
    log("INFO", f"SWITCH {prev or '-'} -> {email} fp={fingerprint(token)}: {reason}")
    if st.get("exhausted", {}).pop(email, None) is not None:
        log("INFO", f"exhausted entry for {email} dropped: it is the pool's account now")
    return True


def pick_next(st: dict, order: List[str], keys: Keys, skip: set, t: float) -> Optional[Tuple[str, str]]:
    """First account of the order that is not known-exhausted, whose key came back from the vault, and whose KEY is accepted NOW
    (validate_key: free). A refused key is recorded. The vault is asked only for the accounts that get this far.

    A candidate is NOT asked whether it has balance: the only call that says is one that is served, and that is paid for - on every
    candidate, on every failover, to learn what the next 429 teaches for nothing. If it turns out to be exhausted too, its sessions
    show the modal and the next run finds out the way this one did (and the account order already ranks the exhausted ones last)."""
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
        pr = validate_key(tok)
        if pr.verdict == "valid":
            return email, tok
        if pr.verdict == "invalid":
            register_exhausted(st, email, pr, t)
        else:
            log("INFO", f"{email} fp={fingerprint(tok)} key check={pr.verdict} {pr.detail} - not a candidate this run")
    return None


def heal_item(st: dict, user: str, token: str, email: str, t: float) -> None:
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
        st["item_at"] = t
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


def ask_due(entry: dict, t: float) -> bool:
    """Has the account NOT answered for this screen within the cooldown? A screen that is new (never asked) is always due: a new screen
    is new evidence, whatever was answered about an older one. A modal that stays on screen is asked again only after the cooldown; an
    envelope that was answered once is never asked about again - it is a line of history that only a new hit replaces."""
    asked = entry.get("asked")
    if asked is None:
        return True
    return bool(entry.get("modal")) and not 0 <= t - asked < evidence_cooldown_s()


def decide(st: dict, keys: Keys, order: List[str], readings: Dict[str, Tuple[Optional[float], str]], user: str, t: float,
           scan: Scan) -> None:
    sanitize_state(st, t)
    track_panes(st, scan, t)
    cur = st.get("current")
    if not cur:
        return reseed(st, keys, order, user, t, None)
    kind, tok = current_credential(st, keys, order, user, cur)
    if kind == "unknown":
        return
    if kind == "gone":
        return reseed(st, keys, order, user, t, cur)

    # Three states, as everywhere: evidence | no evidence | could not look. The API is asked ONLY on the first, and the failback (a move
    # to an account that renewed) only on the second - or once the evidence has been answered, below.
    evidence = fresh_evidence(st, scan)
    may_failback = scan.ok and not evidence
    if not scan.ok:
        log("INFO", "the pool's panes could not be looked at this run - nothing concluded, nothing asked of the API")
    if evidence:
        tracked = st["panes"]
        due = [p for p in evidence if ask_due(tracked[p.key], t)]
        if not due:
            may_failback = True   # the account answered for every one of those screens less than the cooldown ago: it is known to be answering
        else:
            who = ", ".join(sorted({p.agent for p in evidence}))
            word = "modal" if any(p.stuck for p in evidence) else "message"
            log("INFO", f"EVIDENCE: {len(evidence)} pool pane(s) on the limit {word} ({who}) - asking {cur} once for its reply")
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
                # It ANSWERS: the screen was not about this account (another model's limit, a modal about to be dismissed, text that looks
                # like one). What it just answered beats anything stored about it; nothing moves; and those screens are not asked about
                # again until the cooldown has passed (a NEW screen is another matter: it is due at once).
                for p in evidence:
                    tracked[p.key]["asked"] = t
                log("INFO", f"{cur} answers - the limit {word} on screen is not about this account; not asked about the same screen for "
                            f"{int(evidence_cooldown_s())} s")
                if st.get("exhausted", {}).pop(cur, None) is not None:
                    log("INFO", f"exhausted entry for {cur} dropped: it answered the probe, which beats what was stored about it")
                may_failback = True
    if may_failback:
        failback(st, keys, order, readings, user, cur, t)
    now_cur = st.get("current")
    if kind == "item" and now_cur == cur:
        return   # the key of the decision never came from the vault and the item IS that key: nothing to heal against
    key = keys.token(now_cur) if now_cur else None
    if key:
        heal_item(st, user, key, now_cur, t)


def unstick(st: dict, scan: Scan, user: str, t: float) -> None:
    """THE one key this daemon sends: Escape, to a pool pane that is sitting on the limit modal of a credential that was REPLACED. The
    modal does not notice a new credential by itself (ga-2yyitx); Escape returns the session to its prompt, and the conversation goes on
    with the account the item holds now. Every guard below is a reason NOT to press it; see docs/claude-pool-account.md ("The Escape
    exception"). The caller has already run decide(), so the item is in its final state for this run."""
    tracked = st.get("panes")
    if not scan.ok or not isinstance(tracked, dict) or not tracked:
        return
    todo = [p for p in scan.panes if p.stuck and p.key in tracked and stale_modal(st, p, tracked[p.key])
            and tracked[p.key]["tries"] < MAX_ESC_TRIES]
    if not todo:
        return
    off = unstick_disabled()
    if off:
        log("INFO", f"{len(todo)} pool pane(s) still on the limit modal of a replaced credential; unstick disabled by {off} - no key sent")
        return
    at, cur = _sane_epoch(st.get("item_at")), st.get("current")
    if at is None or not cur:
        return
    if t - at < SETTLE_S:
        log("INFO", f"{len(todo)} pool pane(s) on the limit modal of the replaced credential; the item was rewritten {int(t - at)} s ago, "
                    f"waiting {SETTLE_S} s for claude to re-read it before sending Escape")
        return
    ex = st.get("exhausted", {}).get(cur)
    if isinstance(ex, dict) and ex.get("reset_epoch", math.inf) > t:
        log("INFO", f"{cur} is registered as exhausted - no Escape into it")
        return
    kind, held = read_item_token(user)
    fp = st.get("fingerprint")
    if not (kind == "ok" and held and isinstance(fp, str) and fingerprint(held) == fp):
        log("WARN", f"the pool item {'could not be read' if kind == 'unknown' else 'does not hold the credential of the decision'} - no Escape sent")
        return
    sent = 0
    for p in todo:
        if sent >= MAX_ESC_PER_RUN:
            log("INFO", f"{MAX_ESC_PER_RUN} Escapes sent this run - the rest wait for the next one")
            break
        tracked[p.key]["tries"] += 1   # counted BEFORE the attempt: one that fails halfway is still an attempt
        if send_escape(p):
            sent += 1
            log("INFO", f"UNSTICK: Escape sent to pane {p.pane_id} ({p.agent}): it was on the limit modal of the credential replaced at "
                        f"{_iso(at)}; the item holds {cur} fp={fp}")


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
    scan = safe_scan()
    decide(st, Keys(lib), order, readings, user, now(), scan)
    try:
        unstick(st, scan, user, now())
    except Exception as e:  # noqa: BLE001 - the decision above may already have moved the item: it must still be published
        log("ERROR", f"unstick failed ({type(e).__name__}) - no further key sent this run")
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
