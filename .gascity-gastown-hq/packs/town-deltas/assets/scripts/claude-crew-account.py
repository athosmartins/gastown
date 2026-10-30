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
     A bridge that is up says nothing about WHICH account the session is on (ga-ci3uao, 14/10: every bridge was up and the
     Mayor and three crews sat on the old account's limit screen). So the same check also LOOKS at each session's screen
     (read-only: tmux display-message + capture-pane, through the `tmux` field of its session file) and gives each one
     of three answers: on claude's limit screen / clear / cannot tell (no tmux pane, tmux or ps silent, the pane is
     no longer that process's, the limit message on screen but not the modal). Only "clear" for every session is
     `VERIFY ok`; a session on the limit screen is `VERIFY FAILED` (named push `rc-limit-stuck`, `limit_watch` in the state);
     anything else is `NOT VERIFIED`. `verify_last` in the state keeps the verdict.
  5. UNSTICK (opt-in, OFF by default): a session on the limit screen never re-reads the login (the modal waits for a key).
     With `<city>/.gc/crew-unstick-on` (or GC_CREW_UNSTICK=1) the run sends such a session ONE Escape, under the guards
     of the pool daemon's Escape exception (docs/claude-pool-account.md) - see unstick_blocker() and watch_limits(). Every guard is a reason NOT to
     press and "cannot tell" presses nothing. This reverses, for Mayor and the crews, the pool doc's "never pressed": it is
     off until a human turns it on.
  6. THE MESSAGE WITHOUT THE MODAL (ga-yqzedv, opt-in only for the last rung): the real stall of 07/10-25/10 was not the modal. A
     429 ends the turn and leaves "You've hit your weekly limit - resets ..." as the LAST output above the prompt box, the session
     idle, no modal and so nothing to press. That screen used to be "cannot tell" for ever. Now, on claude's measured layout
     (a rule, the `❯` prompt, a rule, the statusline) a session whose last output IS that message goes on `banner_watch`, and the
     difference between current and old is read from the screen, not guessed: the fingerprint of everything above the statusline
     (transcript + prompt box) is kept; it CHANGED = the session is moving (the clock starts over); UNCHANGED for STALL_S = it is
     stopped, and ONE named push (`rc-limit-stalled`) says so. No key is ever sent to that screen (there is no modal: an Escape
     would answer nothing). A layout this script has not measured stays "cannot tell". The last rung, `gc session reset`, exists for
     a stopped session (and for a modal whose Escapes failed), but it is OFF: it starts a FRESH provider conversation (the gc
     docs say so - "fresh provider conversation state" - and 25/10 oracle-wa, recreated by gc, came back with a new session key and
     a transcript that starts empty; `gc session reset` itself was NOT run live, it would have dropped a real conversation), so it
     loses what the session knew. It needs its own arm switch (`<city>/.gc/crew-reset-on` or GC_CREW_RESET=1; arming the Escape does not
     arm it), the same account checklist as the Escape, the session file saying `idle`, the session's own transcript ending in a
     rate_limit error dated AFTER the switch (so "current" is proven, not inferred from the pane: a session idle on an old message
     since before the switch has nothing wrong, its next turn reads the new login), a fresh look right before, and exactly one gc session
     with that tmux name. Once per watch record (a session that comes back on a later switch is a new episode); gc refusing is a named push, never a retry.

Secrets: held in memory; the only place they leave is `security -i` STDIN (hex). Never argv, env, log, state or alert.
Accounts are named by e-mail + sha256[:8] fingerprints.

KNOBS: GC_CREW_ACCOUNT=0 or <city>/.gc/no-crew-account -> the run does nothing. `--dry-run` prints what it WOULD do.
GC_CREW_UNSTICK=1 or <city>/.gc/crew-unstick-on -> the Escape of step 5 is armed; GC_CREW_UNSTICK=0 disarms it whatever the file says.
GC_CREW_RESET=1 or <city>/.gc/crew-reset-on -> the `gc session reset` of step 6 is armed (conversation NOT preserved); GC_CREW_RESET=0 disarms it.
SEAMS (tests): CLAUDE_CREW_GC (the gc binary), CLAUDE_CREW_STATE, CLAUDE_CREW_DECISION, CLAUDE_CREW_ACCOUNTS (json), CLAUDE_CREW_ACCOUNTS_DIR,
CLAUDE_CREW_SECURITY, CLAUDE_CREW_SESSIONS_DIR, CLAUDE_CREW_NOTIFY, CLAUDE_CREW_NOW, CLAUDE_CREW_USER,
CLAUDE_CREW_TMUX (the tmux binary), CLAUDE_CREW_TMUX_SOCKET (default "gascity"),
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
UNVERIFIED_HOLD_S = IDENTITY_TTL_S  # ga-xoe5ao.2: a login written without the profile vouching for it is not written again, unchanged, for this long
OWNERS_KEEP_S = 40 * 86400      # ga-xoe5ao.2: how long the job remembers whose a refresh token was (a refresh token lives ~30 days)
OWNERS_MAX = 64                 # ... and how many it remembers: the newest (one new entry per rotation of the account that holds the default)
HELD_MAX = 32                   # held logins are few; a state that grew past this is pruned, oldest first
VERIFY_AFTER_S = 60            # the CLI re-reads the item every ~30 s; the bridge is checked this long after a switch
VERIFY_GIVE_UP_S = 900          # a check (bridges, owner) made later than this after the switch is not blamed on the switch
MIN_REFRESH_LEFT_S = 86400      # a login whose refresh token has < 1 day left is not a source
ALERT_EVERY_S = 6 * 3600
ALERT_RETRY_S = 300             # a push that was NOT delivered is retried after this, not after ALERT_EVERY_S
# ga-ci3uao - which screen is each Remote Control session on, and the (opt-in) Escape for one on claude's limit screen
DEFAULT_TMUX_SOCKET = "gascity"  # the city's tmux server (`tmux -L gascity`): every gc session, Mayor and crews included, lives in it
LIMIT_WATCH_S = 900              # a session found on the limit screen is watched this long, then the watch is dropped (the push stands)
SETTLE_S = 45                    # claude re-reads the item about every 30 s (measured on 2.1.291, not re-measured on 2.1.300): no key sooner
LOOK_AGAIN_S = 30                # the limit screen must be seen on two runs at least this far apart before any key
MAX_ESC_TRIES = 2                # per session: an Escape that does not take is not repeated for ever
ESC_RETRY_S = 60                 # ... and a second one waits at least this long after the first
MAX_ESC_PER_RUN = 6              # and never an unbounded burst of keys
MAX_RESET_PER_RUN = 1            # a reset loses a conversation: one per run, and one per watch record (see reset_stopped)
LOOK_BUDGET_S = 25                # all the screens of one run, together: the screen check runs BEFORE the follow step, which must not wait minutes for it
STALL_S = 600                    # ga-yqzedv: the limit message is the last output and the screen has not changed for this long = stopped
BANNER_WATCH_S = 3600            # a session on the banner watch is followed this long, then the watch is dropped (the push stands)
LAST_OUTPUT_LINES = 3            # "the last output": the message is among the last lines above the prompt box (a hint line may follow it)
BOX_FOOTER_MAX = 8               # claude's statusline under the prompt box is a handful of lines; more than this is a layout not measured
TRANSCRIPT_TAIL = 262144         # the end of a session's transcript is read, never the whole file
GC_TIMEOUT_S = 60                # gc list / gc session reset
S_LIMIT, S_BANNER, S_CLEAR, S_UNKNOWN = "limit", "banner", "clear", "unknown"
TMUX_FIELD_RE = re.compile(r"[A-Za-z0-9_.-]{1,80}:@\d+\.(%\d+)")   # the `tmux` field of a session file: <session>:@<window>.%<pane>
SOCKET_RE = re.compile(r"[A-Za-z0-9_.-]{1,64}")
BANNER_RE = re.compile(r"hit your\b.{0,40}\blimit\b", re.I)         # "You've hit your weekly limit · resets 8pm"
# the same message as the START of a line: only non-word characters (the glyph, spaces) may come before it, anything may follow. A
# sentence of an agent that merely mentions the message starts with a word, so it does not match
STOP_MSG_RE = re.compile(r"^[^\w]*you['’]ve hit your\b.{0,40}\blimit\b", re.I)
RULE_RE = re.compile(r"^─{10,}$")                                    # the rules around claude's prompt box (2.1.310)
TMUX_SESSION_RE = re.compile(r"([A-Za-z0-9_.-]{1,80}):@\d+\.%\d+")     # the session-name half of the `tmux` field
GC_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
NAME_RE = re.compile(r"[^A-Za-z0-9 ._-]")
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
        note_owner(st, fp(o.get("refreshToken")), e, t)
        return e
    return c.get("email") if fresh else None


def _prune(d: dict, keep_s: float, cap: int, t: float) -> dict:
    """The entries of `d` (fingerprint -> {..., "at": epoch}) younger than `keep_s`, the `cap` newest at most. Whatever is not
    a dict with a time goes: these tables only ever lose knowledge here, they never invent any."""
    live = {k: v for k, v in d.items() if isinstance(k, str) and isinstance(v, dict) and t - _num(v.get("at")) < keep_s}
    if len(live) > cap:
        live = dict(sorted(live.items(), key=lambda kv: _num(kv[1].get("at")), reverse=True)[:cap])
    return live


def note_owner(st: dict, rfp: Optional[str], email: str, t: float) -> None:
    """ga-xoe5ao.2: the PROFILE just said whose the login with this refresh-token fingerprint is. Kept (fingerprint + e-mail,
    never a token), so that a copy of that login found later in ANOTHER account's item is known for what it is."""
    if not rfp or not isinstance(email, str) or not email:
        return
    owners = st.get("owners")
    owners = _prune(owners if isinstance(owners, dict) else {}, OWNERS_KEEP_S, OWNERS_MAX - 1, t)
    owners[rfp] = {"email": email, "at": t}
    st["owners"] = owners


def known_owner(st: Optional[dict], rfp: Optional[str], t: float) -> Optional[Tuple[str, float]]:
    """(e-mail, when) if the profile once said whose the login with this refresh-token fingerprint is; None = nobody ever did."""
    # vazio → None: the job was never told whose it is, so the source goes on as before (the fail-open of step 4: the profile
    # cannot vouch for an expired copy); falhou/ilegível → None too, by that same decision: a damaged table loses knowledge, it never invents any
    owners = (st or {}).get("owners")
    rec = owners.get(rfp) if rfp and isinstance(owners, dict) else None
    e = rec.get("email") if isinstance(rec, dict) else None
    at = _num(rec.get("at")) if isinstance(rec, dict) else 0.0
    return (e, at) if isinstance(e, str) and e and t - at < OWNERS_KEEP_S else None


def hold_login(st: dict, rfp: Optional[str], svc: str, target: str, t: float) -> None:
    """ga-xoe5ao.2: an UNVERIFIED switch was just made from this exact login (same refresh token). Remembered, so that the
    same blind switch is not made again every cycle while nothing has confirmed the login or changed it."""
    if not rfp:
        return
    held = st.get("unverified_logins")
    held = _prune(held if isinstance(held, dict) else {}, UNVERIFIED_HOLD_S, HELD_MAX - 1, t)
    held[rfp] = {"svc": svc, "target": target, "at": t}
    st["unverified_logins"] = held


def release_login(st: dict, rfp: Optional[str]) -> None:
    """The profile has had its say about this login (it is the target's, or somebody else's): nothing is held on it any more."""
    held = st.get("unverified_logins")
    if rfp and isinstance(held, dict):
        held.pop(rfp, None)


def held_login(st: Optional[dict], rfp: Optional[str], t: float) -> Optional[str]:
    """Why this login must not be written again yet (None = it may be): an unverified switch was made from it less than
    UNVERIFIED_HOLD_S ago and neither the profile nor a new login has said anything since."""
    # vazio → None: nothing was written from it without a verdict, so the first unverified switch (the normal production path)
    # goes ahead; falhou/ilegível → HELD: a record that is there but has no usable time is still a hold (the inert side: nothing is written)
    held = (st or {}).get("unverified_logins")
    if not rfp or not isinstance(held, dict) or rfp not in held:
        return None
    rec = held[rfp]
    at = rec.get("at") if isinstance(rec, dict) else None
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        return "at a time its record has lost"
    return None if t - at >= UNVERIFIED_HOLD_S else f"{int(t - at)} s ago"


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
        out[pid] = {"bridge": str(data["bridgeSessionId"]), "start": start,
                    "tmux": data["tmux"] if isinstance(data.get("tmux"), str) else "", "name": _label(data.get("name"), pid)}
    if unread:
        log("WARN", f"{len(unread)} session file(s) could not be read ({', '.join(unread[:5])}"
                    f"{', ...' if len(unread) > 5 else ''}) - a Remote Control bridge in them is NOT counted")
    return out, unread


def bridges() -> Optional[Dict[int, dict]]:
    """The first half of scan_sessions(): who has a bridge now. None = the sessions dir could not be read."""
    s = scan_sessions()
    return None if s is None else s[0]


# ── which screen is a session on? (ga-ci3uao) ───────────────────────────────────────────────────────
# A bridge that is up does not say which account the session uses. The one screen that proves a session did NOT pick up the new
# login is claude's limit modal (measured on 2.1.291 with a really exhausted account, at the bottom of the pane, in place of the prompt):
#
#     What do you want to do?
#     ❯ 1. Stop and wait for limit to reset
#       2. Wait here, then continue automatically at Oct 7 at 7pm
#       3. Upgrade your plan
#     Enter to confirm · Esc to cancel
#
# Every read has three outcomes - limit / clear / cannot tell - and "cannot tell" is never "clear": it is said, and it is never
# a reason to press a key.
def _label(name, pid: int) -> str:
    """A short, plain name for a session in a push / a log line: what the session file calls it, else its pid."""
    n = NAME_RE.sub("", name).strip()[:30] if isinstance(name, str) else ""
    return f"{n} ({pid})" if n else f"pid {pid}"


def tmux_bin() -> Optional[str]:
    p = os.environ.get("CLAUDE_CREW_TMUX")
    if p:
        return p if os.access(p, os.X_OK) else None
    return shutil.which("tmux") or next((c for c in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.access(c, os.X_OK)), None)


def tmux_socket() -> str:
    s = os.environ.get("CLAUDE_CREW_TMUX_SOCKET") or DEFAULT_TMUX_SOCKET
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


def parent_of(pid: int) -> Optional[int]:
    """The parent of `pid`; 0 = no such process; None = could not ask."""
    try:
        r = subprocess.run(["/bin/ps" if os.path.exists("/bin/ps") else "ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                           timeout=5, check=False, env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return 0
    return int(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip().isdigit() else None


def in_pane(pid: int, pane_pid: int) -> Optional[bool]:
    """Is `pid` the process of the pane, or one of its descendants (<= 8 hops)? None = could not ask."""
    cur = pid
    for _ in range(9):
        if cur == pane_pid:
            return True
        p = parent_of(cur)
        if p is None:
            return None
        if p <= 1:
            return False
        cur = p
    return False


def screen_verdict(text: str) -> str:
    """S_LIMIT iff the screen's LAST lines are claude's limit modal: the footer is the last line, and the question and option 1 precede it,
    in that order (while the modal is open it replaces the prompt box, so nothing follows it). A session that merely QUOTES these words
    in its transcript has its prompt box under the quote and is not matched. S_BANNER = the limit message is on the screen but not
    the modal: it may be an old line still in the scrollback, so it is "cannot tell", never "stuck". Otherwise S_CLEAR."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if lines and "Enter to confirm" in lines[-1] and "Esc to cancel" in lines[-1]:
        tail = lines[-10:-1]
        ask = [i for i, ln in enumerate(tail) if "What do you want to do?" in ln]
        opt = [i for i, ln in enumerate(tail) if re.search(r"\b1\.\s*Stop and wait for limit to reset", ln)]
        if ask and opt and ask[-1] < opt[-1]:
            return S_LIMIT
    return S_BANNER if any(BANNER_RE.search(ln) for ln in lines[-25:]) else S_CLEAR


def screen_parts(text: str) -> Optional[Tuple[List[str], List[str]]]:
    """(transcript lines, prompt-box lines) of claude's screen, or None when it is not the layout measured on 2.1.310 (25/10): the
    transcript, then a rule, the `❯` prompt (one or more lines), a rule, and the statusline (a handful of lines) to the end. The
    statusline is left out on purpose: it changes by itself (context %, workers, clock) and says nothing about the session."""
    lines = [ln.rstrip() for ln in text.splitlines()]
    rules = [i for i, ln in enumerate(lines) if RULE_RE.match(ln.strip())]
    if len(rules) < 2:
        return None
    top, bottom = rules[-2], rules[-1]
    if sum(1 for ln in lines[bottom + 1:] if ln.strip()) > BOX_FOOTER_MAX:
        return None
    box = [ln for ln in lines[top + 1:bottom] if ln.strip()]
    if not box or not box[0].lstrip().startswith("❯"):
        return None
    return [ln for ln in lines[:top] if ln.strip()], box


def banner_last(text: str) -> Optional[str]:
    """ga-yqzedv: the fingerprint of the screen iff the limit MESSAGE (no modal) is the last output of claude's measured layout, else None.
    "Last output" = it is one of the last LAST_OUTPUT_LINES lines of the transcript, directly above the prompt box, and it STARTS the
    line (an agent's sentence that mentions it does not). The fingerprint covers the transcript and the prompt box, not the statusline:
    equal on two looks = nothing happened on that screen between them; different = the session is moving (or somebody is typing).
    None is "not that" and also "cannot tell" (a layout not measured: screen_parts() is None) - neither is ever treated as stopped."""
    parts = screen_parts(text)
    if parts is None:
        return None
    body, box = parts
    if not any(STOP_MSG_RE.search(ln.strip()) for ln in body[-LAST_OUTPUT_LINES:]):
        return None
    return hashlib.sha256("\n".join(body + ["\x1e"] + box).encode()).hexdigest()[:12]


def look_screen(pid: int, tmux_field: str) -> Tuple[str, str, str, str]:
    """(verdict, pane id, why, the screen's text). The pane is trusted only if the session's own process lives in it (a recycled pane id
    is another session's screen); anything that cannot be established is S_UNKNOWN with the reason and no text."""
    m = TMUX_FIELD_RE.fullmatch(tmux_field or "")
    if not m:
        return S_UNKNOWN, "", "it reports no tmux pane of the city (not started under the city's tmux)", ""
    pane = m.group(1)
    rc, out = tmux(["display-message", "-p", "-t", pane, "#{pane_pid}"])
    if rc is None:
        return S_UNKNOWN, pane, "tmux could not be run", ""
    if rc != 0 or not out.strip().isdigit():
        return S_UNKNOWN, pane, f"tmux does not know pane {pane}", ""
    mine = in_pane(pid, int(out.strip()))
    if mine is None:
        return S_UNKNOWN, pane, "ps could not say whose pane it is", ""
    if not mine:
        return S_UNKNOWN, pane, f"pane {pane} is not this session's any more", ""
    rc, text = tmux(["capture-pane", "-p", "-J", "-t", pane])
    if rc != 0:
        return S_UNKNOWN, pane, f"the screen of {pane} could not be read", ""
    return screen_verdict(text), pane, "", text


def look(pid: int, tmux_field: str) -> Tuple[str, str, str]:
    """(verdict, pane id, why): look_screen() without the text."""
    return look_screen(pid, tmux_field)[:3]


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
    lost, unverified, up, ended, up_pids = [], [], 0, 0, []
    for pid_s in before:
        pid = _int(pid_s)
        if pid is None or not alive(pid, starts.get(pid_s)):
            ended += 1                     # the session ended on its own: not a switch casualty, and not a bridge that is up
        elif pid in now_b:
            up += 1
            up_pids.append(pid)
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
    try:
        judge_screens(st, to, now_b, up_pids, bool(lost or unverified), t)
    except Exception as e:  # noqa: BLE001 - a bug in the screen check must not cost the switch or the bridge verdict above
        log("ERROR", f"switch to {to}: the screen check failed ({type(e).__name__}) - which account the sessions use is NOT verified")
        st["verify_last"] = {"at": t, "to": to, "verdict": "not-verified", "error": type(e).__name__}
    st.pop("pending_verify", None)
    return True


def look_many(targets: List[Tuple[int, str]]) -> Dict[int, Tuple[str, str, str]]:
    """look() for each (pid, tmux field), inside LOOK_BUDGET_S in all. A loaded machine makes every tmux/ps call slow (load 220-350 on 14/10,
    the very day this was written) and the screen check sits in front of the switch itself: what there is no time left for is S_UNKNOWN, said."""
    out, deadline = {}, time.monotonic() + LOOK_BUDGET_S
    for pid, field in targets:
        out[pid] = look(pid, field) if time.monotonic() < deadline else (S_UNKNOWN, "", "no time was left to look at every screen in this run")
    return out


def look_screens(targets: List[Tuple[int, str]]) -> Dict[int, Tuple[str, str, str, str]]:
    """look_many() that keeps the screen's text too (look_screen), inside the same LOOK_BUDGET_S."""
    out, deadline = {}, time.monotonic() + LOOK_BUDGET_S
    for pid, field in targets:
        out[pid] = look_screen(pid, field) if time.monotonic() < deadline else (
            S_UNKNOWN, "", "no time was left to look at every screen in this run", "")
    return out


def watch_limit(st: dict, to, recs: Dict[int, dict], t: float) -> None:
    """Put sessions (pid -> {start, tmux, name}) on the limit watch: they are on claude's limit screen (the modal)."""
    lw = st.get("limit_watch") if isinstance(st.get("limit_watch"), dict) else {}
    pids = lw.get("pids") if isinstance(lw.get("pids"), dict) else {}
    for p, r in recs.items():
        old = pids.get(str(p)) if isinstance(pids.get(str(p)), dict) else {}
        pids[str(p)] = {"start": r.get("start", ""), "tmux": r.get("tmux", ""), "name": r["name"],
                        "first": _num(old.get("first"), t), "tries": int(_num(old.get("tries"))), "last_try": _num(old.get("last_try"))}
    st["limit_watch"] = {"to": to, "found": _num(lw.get("found"), t), "pids": pids}


def watch_banner(st: dict, to, recs: Dict[int, dict], found: Dict[int, str], t: float) -> None:
    """Put sessions whose last output is the limit message (pid -> screen fingerprint) on the banner watch (ga-yqzedv). A session
    already there with the same fingerprint keeps its clock; a different one starts over."""
    bw = st.get("banner_watch") if isinstance(st.get("banner_watch"), dict) else {}
    pids = bw.get("pids") if isinstance(bw.get("pids"), dict) else {}
    for p, f in found.items():
        r = recs[p]
        old = pids.get(str(p)) if isinstance(pids.get(str(p)), dict) else {}
        same = old.get("fp") == f
        pids[str(p)] = {"start": r.get("start", ""), "tmux": r.get("tmux", ""), "name": r["name"], "fp": f,
                        "since": _num(old.get("since"), t) if same else t, "stalled": old.get("stalled") if same else None,
                        "told": old.get("told") if same else None, "reset": old.get("reset")}
        log("INFO", f"switch to {to}: {r['name']}: the limit message is the last thing on the screen (no modal) - on the watch: stopped "
                    f"if the screen stays unchanged for {STALL_S // 60} min")
    st["banner_watch"] = {"to": to, "found": t, "pids": pids}


def judge_screens(st: dict, to, now_b: Dict[int, dict], up_pids: List[int], bridge_doubt: bool, t: float) -> None:
    """The second half of the post-switch check (ga-ci3uao): a bridge that is up does not say which account the session uses. Looks at
    the screen of every session whose bridge is up and ends in ONE verdict line - `VERIFY ok` only when every one of them was looked at
    and none is on claude's limit screen; `VERIFY FAILED` (a named push, and the session goes on the watch) when one is; `VERIFY NOT
    VERIFIED` for everything else (no tmux pane, tmux or ps silent, the limit message without the modal, a bridge that is in doubt).
    The limit message without the modal stays "not verified" (one look cannot say current from old), but when it is the LAST output of
    claude's measured layout the session also goes on the banner watch, which can (ga-yqzedv)."""
    seen = look_many([(p, now_b[p].get("tmux", "")) for p in sorted(up_pids)])
    stuck = [p for p, v in seen.items() if v[0] == S_LIMIT]
    clear = [p for p, v in seen.items() if v[0] == S_CLEAR]
    cant = [p for p, v in seen.items() if v[0] in (S_UNKNOWN, S_BANNER)]
    label = lambda ps: ", ".join(now_b[p]["name"] for p in ps)  # noqa: E731
    last = {}                                              # pid -> fingerprint: the limit message is the last output, no modal
    try:                                                   # (a second read, of the message-only sessions: look() does not keep the text)
        for p, v in look_screens([(p, now_b[p].get("tmux", "")) for p in cant if seen[p][0] == S_BANNER]).items():
            f = banner_last(v[3]) if v[0] == S_BANNER else None
            if f:
                last[p] = f
        if last:
            watch_banner(st, to, now_b, last, t)
    except Exception as e:  # noqa: BLE001 - the banner watch is an addition: a bug in it must not cost the verdict below
        log("ERROR", f"switch to {to}: the banner probe failed ({type(e).__name__}) - the limit message is not watched")
        last = {}
    if not seen:
        verdict = "nothing-to-look-at"
    elif stuck:
        verdict = "failed"
    elif cant or bridge_doubt:
        verdict = "not-verified"
    else:
        verdict = "ok"
    st["verify_last"] = {"at": t, "to": to, "verdict": verdict, "looked": len(seen), "clear": len(clear),
                         "limit": sorted(stuck), "cannot_tell": sorted(cant)}
    if verdict == "ok":
        log("INFO", f"switch to {to}: VERIFY ok - none of the {len(seen)} sessions looked at is on claude's limit screen")
    elif verdict == "not-verified":
        why = "; ".join(sorted({f"{now_b[p]['name']}: " + (seen[p][2] or (
            f"the limit message is the last thing on the screen, no modal: watched, stopped if unchanged for {STALL_S // 60} min"
            if p in last else "the limit message is on screen but not the modal (old or current: cannot tell)")) for p in cant})[:3])
        log("WARN", f"switch to {to}: VERIFY NOT VERIFIED - which account the sessions use was NOT established ({len(clear)} of "
                    f"{len(seen)} looked at are clear, {len(cant)} could not be told" + (f": {why}" if why else "")
                    + ("; a bridge is also in doubt" if bridge_doubt else "") + ")")
    elif verdict == "failed":
        city_dir = str(city() / ".gc") if city() else "<city>/.gc"
        how = (f"the automatic Escape will be tried (at most {MAX_ESC_TRIES} times each)" if unstick_armed() else
               f"press Esc in each one by hand - the automatic Escape is off (touch {city_dir}/crew-unstick-on to arm it)")
        log("WARN", f"switch to {to}: VERIFY FAILED - {label(stuck)} still on claude's limit screen: they did NOT pick up the new login")
        alert(st, "rc-limit-stuck", f"after the switch to {to} the session(s) {label(stuck)} are still on claude's limit screen: they did "
                                    f"NOT pick up the new login (a session on that screen never re-reads it); {how}", t)
        watch_limit(st, to, {p: now_b[p] for p in stuck}, t)


UNSTICK_OFF = "off"


def unstick_armed() -> bool:
    v = os.environ.get("GC_CREW_UNSTICK")
    if v in ("0", "1"):
        return v == "1"
    c = city()
    return bool(c and (c / ".gc" / "crew-unstick-on").exists())


def reset_armed() -> bool:
    """The `gc session reset` of step 6 has its OWN switch (an authorization is not inherited from the Escape's): the env beats the file, and
    anything but "0"/"1" in the env is not a decision. OFF by default - a reset loses the conversation."""
    v = os.environ.get("GC_CREW_RESET")
    if v in ("0", "1"):
        return v == "1"
    c = city()
    return bool(c and (c / ".gc" / "crew-reset-on").exists())


def unstick_blocker(st: dict, dec, lw: dict, t: float) -> Optional[str]:
    """None = nothing account-level stands in the way of an Escape; else WHY NOT (UNSTICK_OFF = it is not armed)."""
    if not unstick_armed():
        return UNSTICK_OFF
    return account_blocker(st, dec, lw.get("to"), t)


def account_blocker(st: dict, dec, to, t: float) -> Optional[str]:
    """None = nothing account-level stands in the way of touching a session that sits on the limit; else WHY NOT. Every line is a reason
    not to act, and a read that cannot tell is a no - the same checklist as the pool daemon's Escape (docs/claude-pool-account.md)."""
    if not isinstance(dec, dict) or not isinstance(dec.get("current"), str):
        return "there is no pool decision to check the account against"
    if dec["current"].strip().lower() != to or st.get("current") != to:
        return f"the crews are no longer on the {to} of that switch"
    if exhausted(dec, to, t):
        return f"{to} is itself registered exhausted (a session touched now would only land on the next 429)"
    sw = st.get("last_switch")
    if not isinstance(sw, dict) or sw.get("to") != to or t - _num(sw.get("at"), t) < SETTLE_S:
        return "the new login has not been in place long enough for claude to re-read it"
    s, _, cur = kc_read(DEFAULT_SERVICE)
    if s != "ok" or not full_login(cur, t)[0]:
        return "the default item cannot be read, or holds no full login"
    if identity(st, cur, t) != to:
        return f"cannot tell that the default item holds the {to} login"
    return None


def send_escape(pid: int, rec: dict) -> bool:
    """The ONE key this script ever sends. The scan is some seconds old, so look again right before: the same process in the pane, and
    the limit modal still the last thing on its screen. A changed pane gets nothing."""
    verdict, pane, why = look(pid, str(rec.get("tmux") or ""))
    if verdict != S_LIMIT:
        log("INFO", f"{rec.get('name')}: not on the limit screen when the key was due ({why or verdict}) - nothing sent")
        return False
    rc, _ = tmux(["send-keys", "-t", pane, "Escape"])
    if rc != 0:
        log("WARN", f"{rec.get('name')}: tmux send-keys failed (exit={rc})")
        return False
    return True


def session_file(pid: int) -> Optional[dict]:
    """The session file of `pid` as it is NOW (the watch's copy is minutes old), or None when it cannot be read or is not that pid's."""
    d = load_json(sessions_dir() / f"{pid}.json")
    return d if d is not None and _int(d.get("pid") or pid) == pid else None


def _epoch(v) -> Optional[float]:
    """A transcript record's `timestamp` ("2026-10-25T15:40:50.388Z") as epoch seconds; None when it is absent or not that shape."""
    if not isinstance(v, str):
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def transcript_says(sf: dict) -> Tuple[str, Optional[float]]:
    """(what, when) the session's OWN transcript says its last conversation record is. what: "limit" (the rate_limit API error), "later"
    (anything else - it did something after, or something other than hit the limit) or "unknown" (no file, unreadable tail, no record to
    decide on). when: the epoch of that record, for "limit" only, None if it has none. The tail is read, never the whole file; the first
    conversation record from the end decides; a line that cannot be parsed before that is "unknown", not skipped. The transcript lives at
    <config>/projects/<cwd, every non-alphanumeric as ->/<sessionId>.jsonl."""
    sid, cwd = sf.get("sessionId"), sf.get("cwd")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", sid) or not isinstance(cwd, str) or not cwd:
        return "unknown", None
    p = sessions_dir().parent / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd) / f"{sid}.jsonl"
    try:
        with open(p, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(max(0, size - TRANSCRIPT_TAIL))
            raw = f.read(TRANSCRIPT_TAIL)
            cut = size > TRANSCRIPT_TAIL
    except OSError:
        return "unknown", None
    lines = raw.decode("utf-8", "replace").splitlines()
    if cut:
        lines = lines[1:]                                   # the first line of a tail starts in the middle of a record
    for ln in reversed(lines):
        if not ln.strip():
            continue
        try:
            rec = json.loads(ln)
        except (ValueError, RecursionError):
            return "unknown", None
        if not isinstance(rec, dict):
            return "unknown", None
        if rec.get("type") in ("assistant", "user"):
            if rec.get("type") == "assistant" and rec.get("isApiErrorMessage") is True and rec.get("error") == "rate_limit":
                return "limit", _epoch(rec.get("timestamp"))
            return "later", None
    return "unknown", None


def gc_bin() -> Optional[str]:
    p = os.environ.get("CLAUDE_CREW_GC")
    if p:
        return p if os.access(p, os.X_OK) else None
    return shutil.which("gc") or next((c for c in ("/opt/homebrew/bin/gc", "/usr/local/bin/gc") if os.access(c, os.X_OK)), None)


def gc_run(args: List[str]) -> Tuple[Optional[int], str]:
    """(exit code, stdout) of `gc --city <city> <args>`; (None, "") when it could not be run at all (no gc, no city, timeout)."""
    b, c = gc_bin(), city()
    if not b or not c:
        return None, ""
    try:
        r = subprocess.run([b, "--city", str(c)] + args, capture_output=True, text=True, errors="replace", timeout=GC_TIMEOUT_S,
                           check=False, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return r.returncode, r.stdout


def gc_session_id(tmux_field: str) -> Tuple[Optional[str], str]:
    """(gc session id, "") of the ONE gc session whose tmux session is the one in the `tmux` field of a session file, else (None, why).
    Two matches or none is a no: a reset goes to the session that was proven, never to one picked by a guess."""
    m = TMUX_SESSION_RE.fullmatch(tmux_field or "")
    if not m:
        return None, "no gc session can be named: the session reports no tmux session of the city"
    rc, out = gc_run(["session", "list", "--json"])
    try:
        rows = json.loads(out).get("sessions") if rc == 0 else None
    except (ValueError, RecursionError, AttributeError):
        rows = None
    if not isinstance(rows, list):
        return None, f"could not list the gc sessions (exit={rc})"
    ids = [r.get("id") for r in rows if isinstance(r, dict) and r.get("session_name") == m.group(1)]
    if len(ids) > 1:
        return None, f"more than one gc session is called {m.group(1)}"
    if not ids or not isinstance(ids[0], str) or not GC_ID_RE.fullmatch(ids[0]):
        return None, f"no gc session is called {m.group(1)}"
    return ids[0], ""


def reset_stopped(st: dict, dec, to, pid: int, rec: dict, t: float, banner: bool) -> bool:
    """The last rung (step 6): `gc session reset` on a session that has been stopped STALL_S. True = gc was asked to (it worked or not;
    the outcome is pushed and `reset` is set so it is never asked twice); False = a guard said no (logged). It starts a FRESH provider
    conversation (the gc docs, and oracle-wa recreated on 25/10; never run live), so every guard is a reason NOT to: armed (its own
    switch), the account checklist, the same process, the same pane, a fresh look at the screen right before, and - for the limit
    message - the session file saying idle and its own transcript ending in a rate_limit error dated AFTER the switch (an old message
    of a session that has been idle since before it says nothing is wrong: its next turn reads the new login). Once per watch record
    (`reset` in it; a session that leaves the watch and comes back on a later switch is a new episode); gc refusing is a push, never a retry."""
    name = rec.get("name")

    def no(why: str) -> bool:
        log("INFO", f"switch to {to}: {name} was NOT reset - {why}")
        return False

    if not reset_armed():
        return False
    why = account_blocker(st, dec, to, t)
    if why:
        return no(why)
    if not rec.get("start"):
        return no("its session file has no start time, so it cannot be proven to be the same process")
    sf = session_file(pid)
    if sf is None:
        return no("its session file cannot be read now")
    if sf.get("tmux") != rec.get("tmux"):
        return no("its session file now reports another pane than the one that was watched")
    if banner:
        if sf.get("status") != "idle":
            return no(f"not idle: its session file says {sf.get('status')!r}")
        says, when = transcript_says(sf)
        if says != "limit":
            return no(f"its own transcript does not confirm that the limit message is its last word ({says})")
        if when is None or when < _num((st.get("last_switch") or {}).get("at"), t):
            return no("its limit message is not dated after the switch: it may have been idle on it since before the account changed, "
                      "and then its next turn reads the new login - a reset would only lose the conversation")
    verdict, _, why, text = look_screen(pid, str(rec.get("tmux") or ""))
    still = (verdict == S_BANNER and banner_last(text) == rec.get("fp")) if banner else verdict == S_LIMIT
    if not still:
        return no(f"not confirmed stopped right before the reset: the screen is not the one that was watched, or could not be read ({why or verdict})")
    if DRY:
        log("INFO", f"DRY-RUN would run gc session reset for {name} ({pid})")
        return False
    sid, why = gc_session_id(str(rec.get("tmux") or ""))
    if not sid:
        return no(why)
    rec["reset"] = t                                        # counted BEFORE it runs: whatever happens next, it is not run again
    rc, _ = gc_run(["session", "reset", sid])
    key, al = ("rc-limit-reset" if rc == 0 else "rc-limit-reset-failed"), st.setdefault("alerts", {})
    al.pop(key, None)                                       # one per watch record, and each one is news: not held back by another's 6 h window
    if rc == 0:
        log("WARN", f"switch to {to}: {name} was stopped {STALL_S // 60} min on the limit and was reset with gc session reset {sid}")
        alert(st, key, f"{name} was stopped on claude's limit for {STALL_S // 60} min and was reset (gc session reset {sid}): its conversation is "
                       "NOT preserved - it starts a fresh one", t)
    else:
        out = (f"could not be reset (gc session reset {sid} failed, exit={rc})" if rc is not None else
               f"may or may not have been reset (gc session reset {sid} gave no answer: timeout, or gc could not run)")   # no answer != failed
        log("ERROR", f"switch to {to}: {name} {out}")
        alert(st, key, f"{name} is stopped on claude's limit and {out}: look at it, and restart it by hand at an idle moment if it is still stopped", t)
    return True


def watch_banners(st: dict, dec, t: float, resets: Optional[List[int]] = None) -> None:
    """Every run while a session is on the banner watch (step 6): where is the limit message now? gone = off the watch; the modal = it moves
    to the limit watch; still the LAST output = unchanged for STALL_S is "stopped" (one push, then the reset rung when armed), changed
    = moving (the clock starts over). No key is ever sent from here: there is no modal to answer."""
    if "banner_watch" not in st:
        return
    bw = st["banner_watch"]
    pids = bw.get("pids") if isinstance(bw, dict) else None
    if not isinstance(pids, dict) or not isinstance(bw.get("to"), str):
        log("WARN", "the banner_watch record in the state cannot be read - dropped")
        st.pop("banner_watch", None)
        return
    resets = [0] if resets is None else resets
    to, living = bw["to"], []
    for pid_s, rec in list(pids.items()):
        pid = _int(pid_s)
        name = rec.get("name") if isinstance(rec, dict) else None
        if pid is None or not isinstance(rec, dict) or not alive(pid, rec.get("start") or None):
            log("INFO", f"{name or pid_s} ended on its own while on the banner watch - not watched any more")
            pids.pop(pid_s, None)
        else:
            living.append((pid_s, pid, rec))
    looked = look_screens([(pid, str(rec.get("tmux") or "")) for _, pid, rec in living])
    stalled = []
    for pid_s, pid, rec in living:
        name = rec.get("name")
        verdict, _, why, text = looked[pid]
        if verdict == S_CLEAR:
            log("INFO", f"{name} left the limit message - not watched any more")
            pids.pop(pid_s, None)
        elif verdict == S_LIMIT:
            log("INFO", f"{name}: the limit modal is on screen now - moved to the limit watch")
            watch_limit(st, to, {pid: rec}, t)
            pids.pop(pid_s, None)
        elif verdict == S_BANNER:
            f = banner_last(text)
            # vazio (layout measured, the message is gone from the last lines) -> off the watch; ilegivel (layout not measured) -> kept, nothing claimed
            if f is None and screen_parts(text) is None:
                log("WARN", f"{name}: its screen is a layout this script has not measured - kept, nothing claimed")
            elif f is None:
                log("INFO", f"{name}: the limit message is still on screen but is not the last output any more - not watched any more")
                pids.pop(pid_s, None)
            elif f != rec.get("fp"):
                log("INFO", f"{name}: the screen changed since the last look - it is moving, not stopped (the {STALL_S // 60} min start over)")
                rec.update(fp=f, since=t, stalled=None, told=None)
            elif t - _num(rec.get("since"), t) >= STALL_S:
                stalled.append((pid_s, pid, rec))
        else:
            log("WARN", f"{name}: cannot tell what is on its screen ({why or verdict}) - kept, nothing claimed")
    if not pids:
        log("INFO", f"switch to {to}: no session is on the banner watch any more")
        st.pop("banner_watch", None)
        return
    if t - _num(bw.get("found"), t) > BANNER_WATCH_S:
        log("WARN", f"switch to {to}: {', '.join(str(r.get('name')) for r in pids.values() if isinstance(r, dict))} still on the limit message "
                    f"{BANNER_WATCH_S // 60} min after it was found - the watch is dropped (the push stands, nothing more is tried)")
        st.pop("banner_watch", None)
        return
    new = [x for x in stalled if not x[2].get("told")]
    if new:
        for _, _, rec in new:
            rec["stalled"] = _num(rec.get("stalled"), t)
        names = ", ".join(str(r.get("name")) for _, _, r in new)
        c = city()
        how = ("the automatic gc session reset is armed and will be tried (the conversation is NOT preserved)" if reset_armed() else
               f"the automatic gc session reset is off (touch {c / '.gc' if c else '<city>/.gc'}/crew-reset-on arms it; the conversation is NOT "
               "preserved) - restart it by hand at an idle moment")
        one = len(new) == 1
        # always called: alert() logs the stall every time and pushes once per 6 h, so a stall inside another push's window is still in the
        # log; `told` only when the push was delivered (a held-back or failed one is asked again on the next run)
        if alert(st, "rc-limit-stalled", f"after the switch to {to}, {names} {'has' if one else 'have'} had the limit message as the last "
                                         f"thing on the screen for {STALL_S // 60} min and nothing moves: {'it is' if one else 'they are'} "
                                         f"idle at the 429 and nothing will give {'it' if one else 'them'} a new turn by itself ({'it' if one else 'they'} "
                                         f"may also have been idle there since before the switch) - {how}", t):
            for _, _, rec in new:
                rec["told"] = t
    if not reset_armed():
        return
    for pid_s, pid, rec in stalled:
        if rec.get("reset") or resets[0] >= MAX_RESET_PER_RUN:
            continue
        if reset_stopped(st, dec, to, pid, rec, t, banner=True):
            resets[0] += 1
            pids.pop(pid_s, None)
            if not pids:
                st.pop("banner_watch", None)


def watch_limits(st: dict, dec, t: float, resets: Optional[List[int]] = None) -> None:
    """Every run while a session is known to sit on claude's limit screen: has it left? and, when armed, press its Escape (step 5), and,
    when the Escapes did not take and the reset is armed too, the last rung (step 6).
    Looking is read-only and cheap; tmux and ps are not even asked when nothing is on the watch."""
    if "limit_watch" not in st:
        return
    lw = st["limit_watch"]
    pids = lw.get("pids") if isinstance(lw, dict) else None
    if not isinstance(pids, dict) or not isinstance(lw.get("to"), str):
        log("WARN", "the limit_watch record in the state cannot be read - dropped")
        st.pop("limit_watch", None)
        return
    to, due, living = lw["to"], [], []
    for pid_s, rec in list(pids.items()):
        pid = _int(pid_s)
        name = rec.get("name") if isinstance(rec, dict) else None
        if pid is None or not isinstance(rec, dict) or not alive(pid, rec.get("start") or None):
            log("INFO", f"{name or pid_s} ended on its own while on the limit screen - not watched any more")
            pids.pop(pid_s, None)
        else:
            living.append((pid_s, pid, rec))
    looked = look_many([(pid, str(rec.get("tmux") or "")) for _, pid, rec in living])
    for pid_s, pid, rec in living:
        name = rec.get("name")
        verdict, _, why = looked[pid]
        if verdict == S_CLEAR:
            log("INFO", f"{name} left the limit screen (after {rec.get('tries', 0)} Escape(s) from this script)")
            pids.pop(pid_s, None)
        elif verdict == S_LIMIT:
            due.append((pid_s, pid, rec))
        else:
            log("WARN", f"{name}: cannot tell if it is still on the limit screen ({why or 'the limit message without the modal'}) - kept, no key")
    if not pids:
        log("INFO", f"switch to {to}: no session is on the limit screen any more")
        st.pop("limit_watch", None)
        return
    if t - _num(lw.get("found"), t) > LIMIT_WATCH_S:
        log("WARN", f"switch to {to}: {', '.join(str(r.get('name')) for r in pids.values() if isinstance(r, dict))} still not off the limit "
                    f"screen {LIMIT_WATCH_S} s after it was found - the watch is dropped (the push stands, nothing more is tried)")
        st.pop("limit_watch", None)
        return
    if not due:
        return
    why_not = unstick_blocker(st, dec, lw, t)
    if why_not == UNSTICK_OFF:
        return
    if why_not:
        log("INFO", f"switch to {to}: no Escape sent - {why_not}")
        return
    sent, resets = 0, [0] if resets is None else resets
    for pid_s, pid, rec in due:
        tries, name = int(_num(rec.get("tries"))), rec.get("name")
        if tries >= MAX_ESC_TRIES:
            alert(st, "rc-limit-unstick-failed", f"{name} is still on claude's limit screen after {tries} Escape(s) from this script: press "
                                                  "Esc in it by hand, or restart it at an idle moment", t)
            if t - _num(rec.get("first"), t) >= STALL_S and not rec.get("reset") and resets[0] < MAX_RESET_PER_RUN:
                if reset_stopped(st, dec, to, pid, rec, t, banner=False):
                    resets[0] += 1
                    pids.pop(pid_s, None)
                    if not pids:
                        st.pop("limit_watch", None)
        elif sent >= MAX_ESC_PER_RUN or t - _num(rec.get("first"), t) < LOOK_AGAIN_S or t - _num(rec.get("last_try")) < ESC_RETRY_S:
            continue
        elif not rec.get("start"):
            log("WARN", f"{name}: its session file has no start time, so it cannot be proven to be the same process - no key")
        else:
            rec["tries"], rec["last_try"] = tries + 1, t                  # counted BEFORE the key: a key that does not take is not free
            if DRY:
                log("INFO", f"DRY-RUN would send {name} one Escape (try {tries + 1} of {MAX_ESC_TRIES})")
            elif send_escape(pid, rec):
                sent += 1
                log("INFO", f"{name}: Escape sent (try {tries + 1} of {MAX_ESC_TRIES}) - the new login is read on its next request")


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
        rfp = fp(blob["claudeAiOauth"].get("refreshToken"))
        q = bad.get(svc)
        if isinstance(q, dict) and q.get("rfp") == rfp:
            why.append(f"{svc}: quarantined (it turned out to hold {q.get('owner')}'s login, not {email}'s)")
            continue
        k = known_owner(st, rfp, t)           # the NAME of an item is not its owner: a login the profile already gave to someone else is not this one's
        if k and k[0] != email:
            why.append(f"{svc}: holds {k[0]}'s login, not {email}'s (the profile said so on {_iso(k[1])}) - not written as {email}'s")
            continue
        ok, reason = full_login(blob, t)
        if not ok:
            why.append(f"{svc}: {reason}")
            continue
        h = held_login(st, rfp, t)
        if h is not None:
            why.append(f"{svc}: held - an unverified switch from this very login was made {h}, and the profile has not said whose it "
                       f"is since; it is not written again until it is logged in again or {UNVERIFIED_HOLD_S // 3600} h have passed")
            continue
        return (svc, acct, blob), [], False      # type: ignore[return-value]
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
        note_owner(st, un.get("rfp"), owner, t)                # ga-xoe5ao.2: that LOGIN is owner's, wherever a copy of it is kept
        st["unverified_last"] = {"result": "mismatch", "email": target, "owner": owner, "at": t}
    release_login(st, un.get("rfp"))                           # the profile has had its say: the login is not "held" any more
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
        hold_login(st, fp(blob["claudeAiOauth"].get("refreshToken")), svc, target, t)     # ga-xoe5ao.2: this login is not written again, unchanged, every cycle
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
    resets = [0]                                               # a reset loses a conversation: at most MAX_RESET_PER_RUN in all, by either watch
    try:
        watch_limits(st, dec, t, resets)
    except Exception as e:  # noqa: BLE001 - watching the screens must never cost the switch itself
        log("ERROR", f"the limit-screen watch failed ({type(e).__name__}) - the switch goes on")
    try:
        watch_banners(st, dec, t, resets)
    except Exception as e:  # noqa: BLE001 - same: the banner watch is an addition, never a reason to skip the switch
        log("ERROR", f"the banner-watch failed ({type(e).__name__}) - the switch goes on")
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
