#!/usr/bin/env python3
"""claude-login-renew — ga-xoe5ao.5 (slices 1-3 of 3): renew the login of a Claude account of the mini without calling Athos, and call him ONCE when it cannot.

    claude-login-renew.py --account <email> --force      0 = renewed, 2 = not renewed (the line printed and the log say why)
    claude-login-renew.py                                the scheduled run (launchd, every 15 min): lifts the marks of accounts somebody logged in by hand, retries the
                                                         pushes not yet delivered, and launches AT MOST ONE attempt, for the first account the forecast or the outage names
    claude-login-renew.py --dry-run                      the same, but it only SAYS (stderr): nothing launched, written or pushed
    exit: 0 = ran (or nothing to do), 2 = a forced renewal that did not renew, 64 = usage, 1 = the run could not judge (unreadable state / crew state), could not take the lock
          or write its state, or crashed (the log says which)

When the scheduled run acts (one account per run, the forecast first by nearest end, then the outage with the pool's pick first):
  * FORECAST: the best login of a config-dir account (its own item, its reserve) ends within EXPIRY_WARN_S (7 days) or already ended. The account that HOLDS the
    default is left alone while the default is a full login - in the default ITEM or in the credentials FILE the tmux sessions read and rotate in (ga-i4t0lzx): the CLI
    rotates that login and a fresh login of the same account could cost the default its refresh token (not measured).
  * OUTAGE: the crew job has had NO full login in the default item for NO_LOGIN_WARN_S (10 min) AND no account has a stored login the CREW JOB WOULD WRITE. "Usable" is
    the crew job's own judge (its source_refusal): a login it holds back after an unverified switch, quarantined, knows to be another account's, or has burned is NOT usable.
    On 04/11 this job called such logins usable, saw no outage, and stayed silent for the whole of it. The credentials file counts like the default item (a full login in it is
    a login the sessions have); an item or the file that cannot be READ means "unknown": no outage is judged.
  EVERY scheduled run leaves one `scheduled run:` line in the log (accounts looked at, the verdict on the outage, what was launched, who was passed over and why): silence
  means the job did not run, never "nothing to say".
  An account whose mark says "wait" (`recheck_at`, `next_at`) is not touched before that time. Off switch: GC_LOGIN_RENEW=0 or <city>/.gc/no-login-renew.
  Whatever the run cannot KNOW launches nothing (and says so): an unreadable state file or crew state, an item that cannot be read.

What an attempt is: `claude auth login --email <e>` with CLAUDE_CONFIG_DIR = the account's own dir (the crew job finds the new item the next minute),
under a PATH shim for `open`/`xdg-open` that only writes the OAuth URL into a private file - Athos's browser never opens. The URL goes to the DRIVER on
its stdin: this same file, subcommand `drive`, run by a python that has playwright, attached to the Chrome CDP of federated-site-login (profile
~/.chrome-cdp, 127.0.0.1:9222). The driver passes Google with the session that profile already has (account chooser; the TOTP of `gmail-totp <email>`
when Google asks for a code) and clicks Authorize. It never types a password.
The attempt is JUDGED by the Keychain, not by the driver: the item must hold a NEW full login whose profile says it is `<e>`'s. A login that is not
full, or is somebody else's, is put back as it was (or removed, when there was none).

What it does NOT do (Anthropic's anti-abuse is not ours to beat; ga-yyltfk 04/10): when Authorize shows a human-verification puzzle, or Google asks for
a password / a phone tap / a security key, or the profile has no session for that Google account, or the browser is signed in as another account, the
driver STOPS (verdict `puzzle`, `needs_password`, `needs_device`, `no_google_session`, `wrong_account`) and nothing is retried. Slice 2: the account is
then marked "inviavel por automacao" in the state and Athos gets ONE push with the exact step (retried every PUSH_RETRY_S until delivered, never
repeated; notify's exit 12 - the push cap holding a forced push - is answered ONCE with the same text as a decision that waits for Athos, the route the cap exempts); a wall fixed in the BROWSER (CHROME_FIX) is to be looked at again after RECHECK_S (`recheck_at`), a transient failure after RETRY_S (`next_at`),
the 3rd failure in a row is the same mark; a login made by hand (HAND_LOGIN_GAIN_S more life) lifts the mark. Slice 3: the scheduled run READS `recheck_at` and `next_at`.

Secrets: tokens never leave this process except through `security -i` stdin (the crew module's kc_write); the OAuth URL never reaches argv, log or stdout;
accounts are named by e-mail and tokens by sha256[:8] fingerprints.
SEAMS (tests): CLAUDE_RENEW_CLAUDE (the claude binary), CLAUDE_RENEW_DRIVER (json list: the driver command, the URL on stdin), CLAUDE_RENEW_DRIVER_PY,
CLAUDE_RENEW_CDP (default http://127.0.0.1:9222); and every CLAUDE_CREW_* seam of claude-crew-account.py (it is imported).
"""
from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("claude_crew_account_for_renew", HERE / "claude-crew-account.py")
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)               # the crew job's Keychain/profile helpers: one reader of the items, not two

DEFAULT_STATE = "/Users/athos/shared/data/claude_login_renew.json"
RETRY_S = 6 * 3600              # a failed (transient) try is not repeated sooner
MAX_TRIES = 3                   # ... and the third one is final
PUSH_RETRY_S = 300              # a push that was not delivered is retried after this
HAND_LOGIN_GAIN_S = 86400       # a stored login with this much more life than at the mark = somebody logged in by hand
RECHECK_S = 24 * 3600           # a mark whose step is "sign in, in the automation Chrome" is looked at again after this (the one push stands)
URL_WAIT_S = 45                 # the CLI must ask for the browser within this
DRIVE_TIMEOUT_S = 240.0         # the driver's whole budget (it has its own deadline inside, a little shorter)
CLI_WAIT_S = 90.0               # after the driver is done the CLI must finish within this
DRIVE_BUDGET_S = 200            # inside the driver: all the screens together
TOTP_TIMEOUT_S = 30
AFTER_AUTHORIZE_S = 10          # ... after Authorize the driver watches this long for a puzzle, then reports ok (the Keychain, not the driver, judges the login)
CDP_URL = "http://127.0.0.1:9222"
LOGIN_RE = re.compile(r"^https://(claude\.ai|claude\.com|platform\.claude\.com|console\.anthropic\.com)/[^\s]*$")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PUZZLE_RE = re.compile(r"drag the|silhouette|verify (?:that )?you(?:'|’)?re (?:a )?human|human verification|prove you(?:'|’)?re|are you a robot|"
                       r"(?:solve|complete) the captcha|captcha challenge|sharp end of each line|"
                       r"arraste (?:o|a|os|as) |silhueta|verifi(?:que|car) que voc[êe] [ée] (?:um )?humano|verifica[çc][ãa]o humana|prove que voc[êe] [ée]|"
                       r"voc[êe] [ée] (?:um )?rob[ôo]|(?:resolva|conclua) o captcha|desafio (?:de )?captcha", re.I)     # visible words of a challenge, not the footer of a page that merely mentions reCAPTCHA. pt-BR (ga-p0nydy4): the same words in Portuguese; "sharp end of each line" is the hCaptcha prompt Anthropic showed on 08/11
DEVICE_RE = re.compile(r"tap yes|check your (?:phone|device)|security key|passkey|verify it(?:'|’)s you|use your phone|unusual activity|"
                       r"toque em sim|verifique (?:o )?seu (?:telefone|dispositivo|celular)|chave de seguran[çc]a|chave de acesso|"
                       r"(?:confirme|verifique) (?:que|se) [ée] voc[êe]|use seu (?:telefone|celular)|atividade incomum", re.I)     # pt-BR (ga-p0nydy4): the same asks, in Portuguese
CONTINUE_BUTTONS = ("continue", "continuar", "permitir")     # Google's consent screen: "Continue" in English, «Continuar» (and «Permitir») in pt-BR - NEVER «Cancelar»/«Cancel»/«Negar»
CONTINUE_BTN_RE = re.compile(r"^(?:continue|continuar|permitir)$", re.I)     # the click's name match: the same words as CONTINUE_BUTTONS, anchored, so «Cancelar» can never be the button clicked
CHROME_FIX = ("no_google_session", "needs_password")     # fixed in the BROWSER: the job can see it worked. The others are fixed by a login by hand (the Keychain shows it)
PERMANENT = ("puzzle", "no_google_session", "needs_password", "needs_device", "wrong_account")     # a retry cannot change these: a human can
DRY = False                     # --dry-run: logs go to stderr, nothing is written, nothing is pushed, nothing is launched


def rlog(level: str, msg: str) -> None:
    if "sk-ant-" in msg or "authorize?" in msg or "code_challenge" in msg or "state=" in msg:
        msg = "[line withheld: token- or URL-shaped text]"
    line = f"{C._iso(C.now())} pid={os.getpid()} renew {level} " + ("[dry-run] " if DRY else "") + msg
    c = None if DRY else C.city()
    try:
        if c and (c / ".gc" / "logs").is_dir():
            with open(c / ".gc" / "logs" / "claude-login-renew.log", "a") as f:
                f.write(line + "\n")
            return
    except OSError:
        pass
    print(line, file=sys.stderr)


def acct_dir(email: str) -> Optional[Path]:
    d = (C.accounts().get(email) or {}).get("dir")
    if not d:
        return None
    p = Path(str(d))
    return p if p.is_absolute() else C.accounts_dir() / p


# ── the attempt ────────────────────────────────────────────────────────────────────────────────
def make_shim(tmp: Path) -> Path:
    d = tmp / "shim"
    d.mkdir(mode=0o700)
    for n in ("open", "xdg-open"):
        (d / n).write_text("#!/bin/sh\numask 077\nprintf '%s' \"$1\" > \"$RENEW_URL_FILE\"\nexit 0\n")
        (d / n).chmod(0o700)
    return d


def claude_bin() -> str:
    return os.environ.get("CLAUDE_RENEW_CLAUDE") or shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")


def driver_cmd() -> List[str]:
    raw = os.environ.get("CLAUDE_RENEW_DRIVER")
    if raw:
        try:
            v = json.loads(raw)
            if isinstance(v, list) and v and all(isinstance(x, str) for x in v):
                return v
        except ValueError:
            pass
        rlog("WARN", "CLAUDE_RENEW_DRIVER is not a json list of strings - ignored")
    py = os.environ.get("CLAUDE_RENEW_DRIVER_PY") or ("/opt/homebrew/bin/python3" if os.path.exists("/opt/homebrew/bin/python3") else sys.executable)
    return [py, str(Path(__file__).resolve()), "drive"]


def stop(p: subprocess.Popen) -> None:
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(5)


def wait_for_url(cli: subprocess.Popen, url_file: Path) -> Optional[str]:
    end = time.monotonic() + URL_WAIT_S
    while time.monotonic() < end:
        try:
            u = url_file.read_text()
        except OSError:
            u = ""                       # not written yet, or not readable: "no URL yet" - never a guessed one
        if u:
            return u
        if cli.poll() is not None:
            return None
        time.sleep(0.1)
    return None


def run_driver(url: str, email: str) -> Tuple[str, str]:
    """(verdict, step) from the driver's LAST json line. The URL goes in on stdin. No line, a line that is not a verdict, a hang -> a failed try."""
    cmd = driver_cmd()
    try:
        r = subprocess.run(cmd, input=url, capture_output=True, text=True, errors="replace", timeout=DRIVE_TIMEOUT_S, check=False,
                           env={**os.environ, "RENEW_EMAIL": email})
    except subprocess.TimeoutExpired:
        return "driver_timeout", "the driver did not finish in time"
    except (OSError, subprocess.SubprocessError) as e:
        return "driver_failed", f"the driver could not run ({type(e).__name__})"
    for line in reversed(r.stdout.splitlines()):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and isinstance(d.get("verdict"), str) and re.fullmatch(r"[a-z_]{2,40}", d["verdict"]):
            return d["verdict"], str(d.get("step") or "")[:200]
    return "driver_no_verdict", f"the driver (exit {r.returncode}) printed no verdict"


def summary(blob: Optional[dict], t: float) -> Optional[dict]:
    o = (blob or {}).get("claudeAiOauth") or {}
    if not o:
        return None
    left = C._ms_left(o, "refreshTokenExpiresAt", t)
    return {"afp": C.fp(o.get("accessToken")), "rfp": C.fp(o.get("refreshToken")), "rexp": C._iso(t + left) if left is not None else None}


def put_back(svc: str, snap_acct: Optional[str], snap: Optional[dict]) -> bool:
    """The item as it was before the try: rewritten from the snapshot, or deleted when there was none."""
    if snap is not None:
        return C.verified_write(svc, snap_acct or C.login_name(), snap)
    try:
        r = C._sec("delete-generic-password", "-s", svc)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode in (0, 44)


def attempt(email: str, reason: str, t: float) -> Tuple[str, str, Optional[dict]]:
    """(verdict, step, proof). verdict 'renewed' is the only success."""
    d = acct_dir(email)
    svc = C.dir_service(str(d))
    s0, snap_acct, snap = C.kc_read(svc)
    # vazio (missing item) → nothing to put back, a first login; falhou/ilegível (locked keychain, or an item with no login object) → NOT attempted: what cannot be snapshotted cannot be put back
    if s0 == "unknown":
        return "skipped", "the account's item could not be read (or holds no login object), so it cannot be put back if the try goes wrong - nothing launched", None
    tmp = Path(tempfile.mkdtemp(prefix="claude-login-renew-"))
    cli = None
    try:
        d.mkdir(parents=True, exist_ok=True)
        shim, url_file = make_shim(tmp), tmp / "url"
        env = {**os.environ, "CLAUDE_CONFIG_DIR": str(d), "PATH": f"{shim}:{os.environ.get('PATH', '')}", "RENEW_URL_FILE": str(url_file), "BROWSER": str(shim / "open")}
        try:
            cli = subprocess.Popen([claude_bin(), "auth", "login", "--email", email], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, cwd=str(tmp))
        except OSError as e:                                   # no claude on the PATH: a failed try with its name on it, the item was never touched
            return "cli_unavailable", f"cannot run the claude binary ({type(e).__name__}: {str(e)[:80]})", None
        url = wait_for_url(cli, url_file)
        if not url:
            verdict, step = "no_browser_request", "the CLI never asked for a browser"
        else:
            verdict, step = run_driver(url, email)
            url = ""
        try:
            cli.wait(CLI_WAIT_S if verdict == "ok" else 5)
        except subprocess.TimeoutExpired:
            pass
        timed_out = cli.poll() is None
        stop(cli)
    finally:
        if cli is not None:
            stop(cli)
        shutil.rmtree(tmp, ignore_errors=True)
    s1, acct1, now_blob = C.kc_read(svc)
    changed = s1 == "ok" and (snap is None or not C.same_login(now_blob, snap))
    good, unverified = False, False
    if changed and C.full_login(now_blob, t)[0]:          # the Keychain judges, whatever the driver said: a full login of the right account made meanwhile (by hand) is kept
        owner = C.profile_email(now_blob["claudeAiOauth"]["accessToken"])
        # vazio/falhou (the profile cannot answer: network, 5xx) → "owner unverified": the Google account was picked by e-mail, the login is kept and said so
        if owner is not None and owner != email:
            verdict, step = "wrong_account", f"the browser authorized {owner}'s account, not {email}'s"
        else:
            good, unverified = True, owner is None
            if unverified:
                rlog("WARN", f"{email}: the profile could not say whose the new login is - kept (owner unverified)")
    elif verdict == "ok":
        if s1 == "unknown":                               # the read AFTER the try failed: "I could not look" is not "there is no new login" - said as what it is, item left alone
            verdict, step = "keychain_unreadable", "the account's item could not be read after the try, so the try is not judged and the item was left alone - check it by hand"
        else:
            verdict, step = ("cli_timeout" if timed_out else "no_full_login"), "the Keychain item holds no new full login after the try"
    if not good:
        gone = (s1 == "missing" and snap is not None) or changed
        if gone and not put_back(svc, snap_acct, snap):
            rlog("ERROR", f"{email}: the item {svc} could NOT be put back as it was - check it by hand")
            step += " | the item could NOT be put back as it was: check it by hand"          # the caller reads the printed line, not the log
        return verdict, step, None
    return "renewed", "", {"svc": svc, "at": t, "reason": reason, "before": summary(snap, t), "after": summary(now_blob, t), "owner_unverified": unverified}


# ── the state: what each account has, its marks, the one push ──────────────────────────────────
def push(title: str, text: str, urgent: bool = True) -> bool:
    """One `notify -p 4` under notify's STRICT contract (the crew module's `deliver`, ga-xoe5ao.4): delivered = exit 0, 10 (held for 07:00) or 11 (same title < 30 min).
    ga-i4t0lzx: exit 12 is notify's push CAP holding a FORCED push; a wall (only a person ends it - `urgent`, the default here: every push of this job is one) that comes
    back 12 is asked once more as a decision that waits for Athos, the route the cap exempts. The same function as the crew job's: one escalation, not two copies of it."""
    n = os.environ.get("CLAUDE_CREW_NOTIFY") or shutil.which("notify")
    if not n:
        rlog("ERROR", f"no notify binary: the push '{title}' could not be sent")
        return False
    # vazio (nothing printed) → fine, only the exit code counts; falhou/ilegível (cannot run, any exit but 0/10/11) → NOT delivered, said, retried
    return C.deliver(n, title, f"job falhou: claude-login-renew — {text}", urgent, say=rlog)


def state_path() -> Path:
    return Path(os.environ.get("CLAUDE_RENEW_STATE") or DEFAULT_STATE)


def load_state() -> Tuple[dict, str]:
    """(state, 'ok'|'missing'|'unreadable'). Missing is a first run. Unreadable is an EMPTY state, said: a forced run goes on (its marks and tries are lost), the scheduled run launches nothing."""
    try:
        d = json.loads(state_path().read_bytes().decode())
    except FileNotFoundError:
        return {}, "missing"
    except (OSError, ValueError, RecursionError):
        rlog("WARN", f"the state file {state_path()} is unreadable - starting from an empty state (marks and tries are lost)")
        return {}, "unreadable"
    acc = d.get("accounts", {}) if isinstance(d, dict) else None
    if not (isinstance(acc, dict) and all(isinstance(v, dict) for v in acc.values())):      # valid json of the wrong SHAPE is the same unreadable state, not a crash on every run
        rlog("WARN", f"the state file {state_path()} is unreadable (not an object of account records) - starting from an empty state (marks and tries are lost)")
        return {}, "unreadable"
    return d, "ok"


def publish_state(st: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    st["schema"], st["updated"] = 1, C._iso(C.now())
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    try:
        tmp.write_text(json.dumps(st, indent=1, sort_keys=True) + "\n")
        os.replace(tmp, p)
    except OSError:                                            # a full disk must not leave a half-written tmp behind every run
        tmp.unlink(missing_ok=True)
        raise


def save(st: dict) -> Optional[OSError]:
    """publish_state, but a state that cannot be written is RETURNED (the caller says it on the printed line), not raised."""
    try:
        publish_state(st)
    except OSError as e:
        return e
    return None


def acct_rec(st: dict, email: str) -> dict:
    a = st.setdefault("accounts", {}).get(email)
    if not isinstance(a, dict):
        a = st["accounts"][email] = {}
    return a


def holder_of(crew: dict) -> Optional[str]:
    h = crew.get("current")
    return h if isinstance(h, str) else None


def cred_view(crew: dict, t: float) -> dict:
    """The credentials file of the default config dir, as the survey needs it (ga-i4t0lzx): the Mayor's and the crews' sessions run in the launchd Background session,
    where the Keychain cannot be read, so they read - and rotate - THIS file. {'full': a full login that is not dead is in it, 'unread': it may hold one and cannot be looked
    at (unreadable, or a path the crew job refuses: a symlink...), 'state': the crew module's word for it}. A file with no login object, or none at all, says nothing."""
    state, fb, _ = C.read_cred_file()
    full = state == "ok" and C.full_login(fb, t)[0] and C.dead_login(crew, C.fp(fb["claudeAiOauth"].get("refreshToken"))) is None
    return {"full": bool(full), "unread": state in ("unreadable", "refused"), "state": state}


def survey(email: str, crew: dict, t: float, file: Optional[dict] = None) -> dict:
    """What `email` has: best_left (seconds to the end of its best refresh token, None = no end recorded anywhere), full (a usable full login is stored: one the CREW JOB WOULD
    WRITE - its own judge, source_refusal, so the two jobs cannot disagree on 'usable' as they did on 04/11 - or, for the holder of the default, the default item or the
    credentials file holds a full login that is not dead), default_full (the holder's default item or file holds such a login), unread (an item - or, for the holder, the file - that
    could not be read: the account is not judged), no_object (its OWN item parses but holds no login object: it says nothing about a login, yet attempt() will not launch for it -
    what cannot be put back is not touched), refused (the logins that exist but the crew job would not write, with its reason: what the log says when an outage is not fixed by them)."""
    best, full, default_full, unread, no_object, refused = None, False, False, False, False, []
    holder = email == holder_of(crew)
    d = acct_dir(email)
    own = C.dir_service(str(d)) if d else None
    for svc in list(C.source_services(email)) + ([C.DEFAULT_SERVICE] if holder else []):
        s, _, b = C.kc_read(svc)
        # vazio (missing item, an item with no login object) → says nothing; falhou/ilegível (locked keychain, crashed security: 'unknown' with no blob) → NOT judged this run
        if s == "unknown" and b is None:
            unread = True
        elif s == "ok" and b:
            o = b["claudeAiOauth"]
            left = C._ms_left(o, "refreshTokenExpiresAt", t)
            if left is not None:
                best = left if best is None else max(best, left)
            if svc == C.DEFAULT_SERVICE:                       # the LIVE login of the holder, not a source: the crew job's rule for it is full and not dead
                why = None if C.full_login(b, t)[0] and not C.dead_login(crew, C.fp(o.get("refreshToken"))) else "not a usable full login"
            else:
                why = C.source_refusal(crew, email, svc, b, t)
            if why is None:
                full, default_full = True, default_full or svc == C.DEFAULT_SERVICE
            elif svc != C.DEFAULT_SERVICE and C.full_login(b, t)[0]:
                refused.append(f"{svc}: {why}")                # a full login that exists and that the crew job would not write: said, it is why an outage is not mended by it
        elif s == "unknown" and svc == own:
            no_object = True
    only_file = False
    if holder and file is not None:
        if file["unread"]:
            only_file, unread = not unread, True
        elif file["full"]:
            full = default_full = True
    return {"best_left": best, "full": full, "default_full": default_full, "unread": unread, "no_object": no_object, "refused": refused, "unread_file": only_file}


def release_marks(st: dict, crew: dict, t: float) -> None:
    """A mark is lifted when somebody logged the account in by hand: its best login now has HAND_LOGIN_GAIN_S more life than when it was marked,
    or it now has a login with a recorded end where the mark found none."""
    for email, a in list((st.get("accounts") or {}).items()):
        mark = a.get("infeasible")
        if not isinstance(mark, dict):
            continue
        if "left" not in mark:                                 # every mark is written with a `left` (None = the mark found no login): without it the record is not ours to read
            rlog("WARN", f"{email}: the mark has no `left` - it cannot be compared with a login, so it stands")
            continue
        v, was = survey(email, crew, t), mark["left"]
        # vazio (the item says nothing now) / falhou (cannot be read now) → the mark stands, the inert side; only a MEASURED login lifts it
        if v["unread"]:
            rlog("WARN", f"{email}: marked, and an item of the account cannot be read - the mark stands until it can be")
            continue
        if v["best_left"] is None:
            continue
        if was is None or (isinstance(was, (int, float)) and not isinstance(was, bool) and v["best_left"] >= was + HAND_LOGIN_GAIN_S):
            a.pop("infeasible")
            a.pop("tries", None)
            a.pop("next_at", None)
            rlog("INFO", f"{email}: logged in by hand - the mark is lifted, back in rotation")


def step_text(email: str, mark: dict) -> str:
    verdict, step, left, at = str(mark.get("verdict") or ""), str(mark.get("step") or ""), mark.get("left"), mark.get("at")
    chrome = ("sign this Google account in ONCE in the automation Chrome on the mini (profile ~/.chrome-cdp, `cdp status`; password and 2-step by you, "
              "nothing passes through an agent). Once it is done the job notices within about a day and the renewal is automatic again")
    hand = C.relogin_cmd(email)
    why = {
        "puzzle": f"Anthropic asked a human-verification puzzle at 'Authorize' (not circumvented). Log {email} in by hand, once, in the mini's Terminal: {hand}",
        "no_google_session": f"the Google account {email} is not signed in in the automation Chrome, so the job cannot pick it. Step: {chrome}.",
        "needs_password": f"Google asked for the password of {email} (the job never types one). Step: {chrome}.",
        "needs_device": f"Google asked {email} for a step the job does not do (a phone tap / security key / extra check). Do it once: {hand}",
        "wrong_account": f"the automation Chrome is signed in to claude.ai as another account, so Authorize would log the wrong one. Step: {hand}",
    }.get(verdict)
    if why is None:
        why = f"{MAX_TRIES} automatic tries failed (last: {step or verdict}). Step: {hand}"
    if isinstance(left, (int, float)) and not isinstance(left, bool) and isinstance(at, (int, float)) and not isinstance(at, bool):
        ends = f"Its login ends {C._iso(at + left)}." if left > 0 else "Its login has already ended."
    else:
        ends = "No end of its login is recorded."                                 # the mark found no login to measure: said as that, not as "soon"
    warn = step.split(" | ", 1)[1] if " | " in step else ""                       # what attempt() appended when the item could NOT be put back: Athos must hear it too
    return f"{email} cannot be renewed automatically ({verdict}): {why} {ends}" + (f" ATTENTION: {warn}" if warn else "")


def tell(st: dict, email: str, t: float) -> None:
    """ONE push per mark: retried every PUSH_RETRY_S while notify does not deliver it, never again once it did. The verdict is in the TITLE: notify drops a push whose title went out < 30 min ago."""
    mark = acct_rec(st, email).get("infeasible")
    if not isinstance(mark, dict) or mark.get("pushed") or t < C._num(mark.get("next_push")):
        return
    mark["next_push"] = t + PUSH_RETRY_S
    if push(f"Relogin automatico impossivel ({mark.get('verdict', '?')}): {email}", step_text(email, mark)):
        mark["pushed"] = t


def mark_infeasible(st: dict, email: str, verdict: str, step: str, left, t: float) -> None:
    a = acct_rec(st, email)
    old = a.get("infeasible") if isinstance(a.get("infeasible"), dict) else {}
    mark = {"verdict": verdict, "step": step, "at": t, "left": left}
    if verdict in CHROME_FIX:
        mark["recheck_at"] = t + RECHECK_S
    if old.get("verdict") == verdict:                          # the same wall again: the push that was sent stands (a NEW wall is a new step for Athos, so a new push)
        mark.update({k: old[k] for k in ("pushed", "next_push") if k in old})
    a["infeasible"] = mark
    rlog("WARN", f"{email}: marked 'inviavel por automacao' ({verdict}: {step}) - one push; " + (f"looked at again after {RECHECK_S // 3600} h" if verdict in CHROME_FIX else "no more tries until it is logged in by hand"))


def run_account(st: dict, crew: dict, email: str, reason: str, t: float) -> Tuple[str, str, Optional[dict]]:
    """One attempt and what it leaves in the state: a proof clears the account's tries and mark; a wall marks it; a transient failure counts."""
    a = acct_rec(st, email)
    v, t0 = survey(email, crew, t), t
    if v["unread"]:                                            # a mark's `left` taken with an item missing from the measure could lift the mark later when nobody logged in by hand
        verdict, step, proof = "skipped", "an item of the account could not be read, so its login is not judged - nothing launched", None
    else:
        rlog("INFO", f"renewing {email} ({reason}): claude auth login in {acct_dir(email)}")
        verdict, step, proof = attempt(email, reason, t)
        t = C.now()                                            # the attempt takes minutes: the marks, tries and pushes are dated when it ENDED
    left = None if v["best_left"] is None else v["best_left"] - (t - t0)      # as of `at` (the push shows the end of the login to the second)
    a["last"] = {"verdict": verdict, "step": step, "at": t}
    if proof:
        for k in ("tries", "next_at", "infeasible"):
            a.pop(k, None)
        a["renewed"] = proof
    elif verdict == "skipped":                                 # nothing was launched: not a failed try
        rlog("WARN", f"{email}: {step}")
    elif verdict in PERMANENT:
        mark_infeasible(st, email, verdict, step, left, t)
    else:
        a["tries"] = int(C._num(a.get("tries"))) + 1
        a["next_at"] = t + RETRY_S
        rlog("WARN", f"{email}: try {a['tries']} of {MAX_TRIES} failed ({verdict}: {step})")
        if a["tries"] >= MAX_TRIES:
            mark_infeasible(st, email, f"failed_{MAX_TRIES}_times", f"{verdict}: {step}", left, t)
    return verdict, step, proof


def settle(st: dict, emails: List[str], t: float) -> Optional[OSError]:
    """The state is written BEFORE the pushes (a crash in between re-sends a wall, it does not forget it), the pushes go, the state is written again.
    A state that cannot be written is RETURNED (the caller says it) and never keeps Athos from hearing about a wall."""
    errs = [save(st)]
    for email in emails:
        tell(st, email, t)
    errs.append(save(st))
    return next((e for e in errs if e), None)


def disabled() -> Optional[str]:
    """What switches the job off (None = on): GC_LOGIN_RENEW=0, or the file <city>/.gc/no-login-renew. No reload of anything needed."""
    if os.environ.get("GC_LOGIN_RENEW") == "0":
        return "GC_LOGIN_RENEW=0"
    c = C.city()
    if c is None:                                              # falhou: the file switch cannot be looked at (only GC_LOGIN_RENEW=0 can switch it off) - the run goes on, but it SAYS so
        rlog("WARN", "GC_CITY_PATH is not set: the file switch .gc/no-login-renew cannot be looked at (GC_LOGIN_RENEW=0 still switches the job off)")
    return str(c / ".gc" / "no-login-renew") if c and (c / ".gc" / "no-login-renew").exists() else None


def candidates(st: dict, crew: dict, dec, t: float, facts: Optional[dict] = None) -> List[Tuple[str, str]]:
    """(email, reason) in the order they should be tried: the forecast by nearest end, then the outage with the pool's pick first.
    `facts`, when given, is filled with what the run's summary line says (ga-i4t0lzx: a run that judges nothing to do must still say so): accounts (how many were looked at),
    outage (the verdict on the outage, in words) and passed (the accounts that were DUE and not launched, each with why)."""
    facts = facts if facts is not None else {}
    passed = facts.setdefault("passed", [])
    holder = holder_of(crew)
    cf = cred_view(crew, t)                                    # read ONCE: the file is the holder's second store (the sessions read and rotate in it), not an account's
    surveys = {e: survey(e, crew, t, cf) for e in C.accounts()}      # ALL of them: an account with no config dir (a backup or reserve item) is a login the crew job heals from
    facts["accounts"] = len(surveys)
    forecast, outage = [], []
    ep = crew.get("no_login")
    since = ep.get("since") if isinstance(ep, dict) and isinstance(ep.get("since"), (int, float)) and not isinstance(ep.get("since"), bool) else None
    in_outage = since is not None and not ep.get("ending") and t - since >= C.NO_LOGIN_WARN_S
    mins = int((t - since) // 60) if since is not None else 0
    unknown = cf["unread"] or any(v["unread"] for v in surveys.values())      # an item or the file that may hold a login and cannot be looked at: "no login anywhere" cannot be said
    has_login = [e for e, v in surveys.items() if v["full"]] + (["the credentials file"] if cf["full"] and holder is None else [])
    none_usable = in_outage and not unknown and not cf["full"] and all(not v["full"] for v in surveys.values())
    if cf["unread"]:
        rlog("WARN", f"the credentials file {C.cred_file()} could not be read ({cf['state']}): whether the sessions have a login is unknown, so no outage is judged"
                     + (f" and {holder} is not judged this run" if holder else ""))
    if since is None or (isinstance(ep, dict) and ep.get("ending")):
        facts["outage"] = "no outage"
    elif not in_outage:
        facts["outage"] = f"an outage of {mins} min, younger than {C.NO_LOGIN_WARN_S // 60} min: no outage is judged yet"
    elif unknown:
        facts["outage"] = f"an outage of {mins} min, but whether any account has a login is unknown (an item or the credentials file could not be read): no outage is judged"
    elif has_login or cf["full"]:
        facts["outage"] = (f"an outage of {mins} min, but a login the crew job will write is stored ({', '.join(has_login) or 'the credentials file'}): it heals from it, no outage is judged")
    else:
        why = [r for v in surveys.values() for r in v["refused"]]
        facts["outage"] = f"an outage of {mins} min and no stored login the crew job would write" + (f" (it refuses: {'; '.join(why)})" if why else "")
    pick = str((dec or {}).get("current") or "").strip().lower() if isinstance(dec, dict) else ""
    for email, v in surveys.items():
        a = (st.get("accounts") or {}).get(email) or {}
        due = "forecast" if v["best_left"] is not None and v["best_left"] <= C.EXPIRY_WARN_S else "outage" if none_usable else None
        if v["unread"]:
            what = "the credentials file" if v["unread_file"] else "an item"
            rlog("WARN", f"{email}: {what} could not be read - the account is not judged this run" + ("" if acct_dir(email) else " (and whether any account has a login is unknown, so no outage is judged)"))
            if due:
                passed.append(f"{email} ({what} could not be read)")
            continue
        if not acct_dir(email):                                # nothing to log into: it only counts as a login that may exist (none_usable above), never as a candidate
            continue
        if email == holder and v["default_full"]:
            rlog("INFO", f"{email} holds the default and it is a full login - not touched (its rotation keeps it alive)")
            if due:
                passed.append(f"{email} (holds the default, a full login)")
            continue
        # vazio (no mark) → candidate; a mark whose recheck_at has come → looked at again; falhou/ilegível (a mark that is no object, a recheck_at that is no number) → stays marked, SAID
        if "infeasible" in a:
            mk = a["infeasible"]
            if not isinstance(mk, dict):
                rlog("WARN", f"{email}: the mark is not an object - the account is not touched until the state is fixed")
                if due:
                    passed.append(f"{email} (its mark in the state file is damaged)")
                continue
            if "recheck_at" in mk and (not isinstance(mk["recheck_at"], (int, float)) or isinstance(mk["recheck_at"], bool)):
                rlog("WARN", f"{email}: the mark's recheck_at is not a number - the account is not touched until the state is fixed")
                if due:
                    passed.append(f"{email} (its mark in the state file is damaged)")
                continue
            if not t >= C._num(mk.get("recheck_at"), float("inf")):    # a wall with no recheck_at waits for a login by hand; one with a recheck_at waits for it
                if due:
                    again = f"looked at again after {C._iso(mk['recheck_at'])}" if "recheck_at" in mk else "waits for a login by hand"
                    passed.append(f"{email} (marked '{mk.get('verdict', '?')}', {again})")
                continue
        wait = a.get("next_at", 0.0)
        if not isinstance(wait, (int, float)) or isinstance(wait, bool):
            rlog("WARN", f"{email}: next_at is not a number - the account is not touched until the state is fixed")
            if due:
                passed.append(f"{email} (its wait in the state file is damaged)")
            continue
        if t < wait:
            if due:
                passed.append(f"{email} (waits until {C._iso(wait)})")
            continue
        if due and v["no_object"]:                             # the SAME precondition attempt() has: an account it would refuse must not be first in line and starve the ones behind it
            rlog("WARN", f"{email}: due ({due}) but its item holds no login object (a logged-out CLI), so nothing can be launched for it - by hand: {C.relogin_cmd(email)}")
            passed.append(f"{email} (a logged-out CLI: nothing to launch for)")
        elif due == "forecast":
            forecast.append((v["best_left"], email))
        elif due == "outage":
            outage.append((0 if email == pick else 1, email))
    return [(e, "forecast") for _, e in sorted(forecast)] + [(e, "outage") for _, e in sorted(outage)]


def run_once(email: str) -> int:
    """Renew `email` now. 0 = renewed; 2 = not (a wall the job does not get around, a failed try, an account with no config dir, a job switched off): the line says which."""
    off = disabled()
    if off:
        print(f"{email}: the job is switched off ({off}) - nothing done", file=sys.stderr)
        return 2
    if email not in C.accounts() or not acct_dir(email):
        print(f"{email}: not one of the accounts with a config dir ('no config dir' = nothing to log into) - nothing done", file=sys.stderr)
        return 2
    t, (st, st_status) = C.now(), load_state()
    crew, crew_status = C.load_state()
    if crew_status != "ok":                                    # who holds the default is then unknown, and a fresh login of the holder could cost the default its refresh token
        print(f"{email}: the crew state {C.state_path()} is {crew_status}, so whether this account holds the default is unknown - nothing done", file=sys.stderr)
        return 2
    if DRY:
        v = survey(email, crew, t)
        why = ("an item of the account cannot be read, so its login is not judged" if v["unread"]
               else "its item holds no login object, so it could not be put back if the try went wrong" if v["no_object"] else "")
        print(f"{email}: [dry-run] " + (f"would be SKIPPED (exit 2): {why}" if why else "would renew it now (forced)") + " - nothing launched", file=sys.stderr)
        return 0
    verdict, step, proof = run_account(st, crew, email, "forced", t)
    t = C.now()
    if proof:
        b, a = proof["before"], proof["after"]
        line = (f"{email}: renewed; item {proof['svc']}: access {b['afp'] if b else 'none'} -> {a['afp']}, refresh {b['rfp'] if b else 'none'} -> {a['rfp']}, ends {a['rexp']}"
                + (" (owner unverified: the profile could not say whose the login is)" if proof["owner_unverified"] else ""))
    else:
        line = f"{email}: NOT renewed ({verdict}: {step})"
    err = settle(st, [email], t)
    mark, tries = acct_rec(st, email).get("infeasible"), acct_rec(st, email).get("tries")
    if not proof and verdict != "skipped" and not isinstance(mark, dict) and tries:
        line += f" - failed try {int(C._num(tries))} of {MAX_TRIES}"
    if isinstance(mark, dict):
        again = f"looked at again after {RECHECK_S // 3600} h" if mark.get("verdict") in CHROME_FIX else "no automatic retry until it is logged in by hand"
        line += (f" - marked 'inviavel por automacao' ({again}); by hand: {C.relogin_cmd(email)}. "
                 + ("Athos was told (one push)." if mark.get("pushed") else f"The push was NOT delivered: the scheduled run retries it (not before {PUSH_RETRY_S // 60} min from now)."))
    if st_status == "unreadable":
        line += " | the state file was unreadable: the marks, tries and pushes of the OTHER accounts were lost (said in the log)"
    if err:
        rlog("ERROR", f"{email}: the state could not be written ({type(err).__name__}): this run's marks and tries are lost")
        line += f" | the state file could not be written ({type(err).__name__}): this run's marks, tries and push are NOT recorded"
    rlog("INFO" if proof else "WARN", line)
    print(line)
    return 0 if proof else 2


def housekeeping() -> int:
    """The scheduled run: lifts the marks of accounts somebody logged in by hand, retries the pushes that were not delivered, and launches AT MOST ONE attempt (the first candidate that can be launched).
    0 = ran; 1 = it could not judge (state or crew state unreadable) or could not write its state: it launched nothing it could not judge, and the log says why."""
    off = disabled()
    if off:
        rlog("INFO", f"switched off ({off}) - nothing done")
        return 0
    t, (st, st_status) = C.now(), load_state()
    if st_status == "unreadable":                              # without the marks and tries a wall would be met (and pushed) again: nothing is launched, pushed or written
        rlog("ERROR", f"nothing launched, pushed or written until {state_path()} is fixed or removed: without its marks the job would push the same wall again")
        return 1
    crew, crew_status = C.load_state()
    todo, facts, launched = [], {}, None
    if crew_status == "ok":
        release_marks(st, crew, t)
        todo = candidates(st, crew, C.load_json(C.decision_path()), t, facts)
    else:                                                      # who holds the default and who has no login is unknown: no login is judged, only the pending pushes go
        rlog("ERROR", f"the crew state {C.state_path()} is {crew_status}: no login is judged and nothing is launched")
    if todo and DRY:
        rlog("INFO", f"{todo[0][0]}: would be renewed now ({todo[0][1]}) - nothing launched" + (f"; then, in later runs: {', '.join(e for e, _ in todo[1:])}" if todo[1:] else ""))
        launched = f"would launch {todo[0][0]} ({todo[0][1]})"
    else:
        for email, reason in todo:
            verdict, _, _ = run_account(st, crew, email, reason, t)
            t = C.now()
            if verdict != "skipped":                           # a try that launched NOTHING (skipped) does not use up the run: the next in line gets it, so one account that cannot be tried never starves the rest
                launched = f"launched {email} ({reason}): {verdict}"
                break
            facts.setdefault("passed", []).append(f"{email} (nothing could be launched for it)")
    if crew_status == "ok":                                    # ga-i4t0lzx: EVERY scheduled run leaves a line - 04/11 13:48Z-15:00Z the log stood still and silence looked the same as a job that was not running
        passed = facts.get("passed") or []
        rlog("INFO", f"scheduled run: {facts.get('accounts', 0)} account(s) looked at; {facts.get('outage', 'no outage')}; " + (launched or "nothing launched")
             + (f"; passed over: {', '.join(passed)}" if passed else ""))
    err = None if DRY or not st.get("accounts") else settle(st, list(st["accounts"]), t)
    if err:
        rlog("ERROR", f"the state could not be written ({type(err).__name__}): this run's marks, tries and pushes are NOT recorded")
    return 0 if crew_status == "ok" and not err else 1


# ── the driver (python with playwright; runs attached to the Chrome CDP) ───────────────────────
def valid_oauth_url(u: str) -> bool:
    return isinstance(u, str) and "\n" not in u and "\r" not in u and bool(LOGIN_RE.fullmatch(u)) and urllib.parse.urlparse(u).hostname in (
        "claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com")


def classify(email: str, url: str, text: str, ids: List[str], has_pw: bool, has_code: bool, buttons: List[str], has_email_box: bool = False) -> str:
    """One screen -> one answer. Pure. A puzzle outranks everything: nothing is clicked on it."""
    u = urllib.parse.urlparse(url)
    host, me = (u.hostname or ""), email.lower()
    if PUZZLE_RE.search(text):
        return "puzzle"
    if host in ("localhost", "127.0.0.1"):
        return "done"
    if host == "accounts.google.com":
        if has_pw:
            return "needs_password"
        if has_code:
            return "enter_code"
        if ids:
            return "pick" if me in [i.lower() for i in ids] else "no_google_session"
        if DEVICE_RE.search(text):
            return "needs_device"
        if has_email_box:                      # Google asks WHICH e-mail to sign in: the profile has no Google session at all, and the job does not type an e-mail into it
            return "no_google_session"
        return "click_continue" if any(b in CONTINUE_BUTTONS for b in buttons) else "wait"
    if host in ("claude.ai", "claude.com") or host.endswith((".claude.ai", ".claude.com")):      # exact or a true subdomain (leading dot): "evilclaude.com" is nobody's
        if "authorize" in buttons:
            seen = {x.lower() for x in EMAIL_RE.findall(text)}
            return "wrong_account" if seen and me not in seen else "click_authorize"
        if "continue with google" in buttons:
            return "click_google"
    return "wait"


def look(pg) -> dict:
    def n(sel: str) -> int:
        try:
            return pg.locator(sel).count()
        except Exception:  # noqa: BLE001 - a page in the middle of a navigation: "none seen", the next look asks again
            return 0
    try:
        text: Optional[str] = pg.inner_text("body", timeout=3000)
    except Exception:  # noqa: BLE001 - None = "could not read the page", which the driver never treats as a page with nothing on it: no puzzle check is possible, so nothing is clicked
        text = None
    try:
        ids = [x for x in (e.get_attribute("data-identifier") for e in pg.locator("[data-identifier]").all()) if x]
        buttons = [b.strip().lower() for b in pg.locator("button, [role=button]").all_inner_texts() if b.strip()]
    except Exception:  # noqa: BLE001
        ids, buttons = [], []
    return {"url": pg.url, "text": text, "ids": ids, "pw": n("input[type=password]:visible") > 0,
            "code": n("input[name=totpPin]:visible, input[type=tel]:visible") > 0, "buttons": buttons,
            "email_box": n("input[type=email]:visible, #identifierId:visible") > 0}


def drive() -> int:
    """stdin: the OAuth URL. stdout: json lines, the last one is the verdict. Never prints the URL, a page's text, an e-mail's password or a code."""
    email = os.environ.get("RENEW_EMAIL", "").strip().lower()
    url = sys.stdin.read().strip()

    def say(verdict: str, step: str = "") -> int:
        print(json.dumps({"verdict": verdict, "step": step}), flush=True)
        return 0
    if not valid_oauth_url(url) or not EMAIL_RE.fullmatch(email):
        return say("error", "not an Anthropic OAuth url / no account")
    from playwright.sync_api import sync_playwright   # only importable from the homebrew python (3.14), which is why this is a separate process
    clicked: Dict[str, int] = {}
    auth_at = None                                   # when Authorize was clicked: ten quiet seconds after it (no puzzle) = the callback is on its way
    end = time.monotonic() + DRIVE_BUDGET_S
    with sync_playwright() as p:
        try:
            br = p.chromium.connect_over_cdp(os.environ.get("CLAUDE_RENEW_CDP") or CDP_URL, timeout=15000)
        except Exception as e:  # noqa: BLE001
            return say("error", f"the automation Chrome is not reachable ({type(e).__name__}): `cdp restart`")
        ctx = br.contexts[0]                         # the profile's own context: the Google session Athos signed in once
        owned = [ctx.new_page()]                     # ONLY our own tab and the popups IT opens: the profile is shared (federated-site-login, Athos), so a tab someone else opens is never read, clicked or closed

        def adopt(pg) -> None:
            owned.append(pg)
            pg.on("popup", adopt)
        owned[0].on("popup", adopt)
        last = "start"
        try:
            owned[0].goto(url, wait_until="domcontentloaded", timeout=30000)
            while time.monotonic() < end:
                for pg in [q for q in owned if not q.is_closed()]:
                    s = look(pg)
                    if s["text"] is None:
                        last = "the page text could not be read"
                        continue
                    act = classify(email, s["url"], s["text"], s["ids"], s["pw"], s["code"], s["buttons"], s["email_box"])
                    host = urllib.parse.urlparse(s["url"]).hostname or ""
                    last = f"{act} at {host}{urllib.parse.urlparse(s['url']).path[:40]}"
                    if act in PERMANENT:
                        return say(act, last)
                    if act == "done":
                        return say("ok", last)
                    if auth_at is not None and time.monotonic() - auth_at > AFTER_AUTHORIZE_S:
                        return say("ok", "authorized, no challenge followed")
                    if act == "wait" or clicked.get(act, 0) >= 3:
                        continue
                    clicked[act] = clicked.get(act, 0) + 1
                    try:
                        if act == "click_google":
                            pg.get_by_role("button", name=re.compile("continue with google", re.I)).first.click(timeout=5000)
                        elif act == "pick":
                            pg.locator("[data-identifier]").filter(has_text=re.compile(re.escape(email), re.I)).first.click(timeout=5000)
                        elif act == "click_continue":
                            pg.get_by_role("button", name=CONTINUE_BTN_RE).first.click(timeout=5000)
                        elif act == "click_authorize":
                            pg.get_by_role("button", name=re.compile(r"^authorize", re.I)).first.click(timeout=5000)
                            auth_at = time.monotonic()
                        elif act == "enter_code":
                            r = subprocess.run(["gmail-totp", email], capture_output=True, text=True, timeout=TOTP_TIMEOUT_S, check=False)
                            code = r.stdout.strip()
                            if r.returncode != 0 or not re.fullmatch(r"\d{6,8}", code):
                                return say("error", f"gmail-totp gave no code (exit {r.returncode})")
                            pg.locator("input[name=totpPin], input[type=tel]").first.fill(code, timeout=5000)
                            pg.keyboard.press("Enter")
                    except Exception as e:  # noqa: BLE001 - a click that did not take is looked at again; 3 tries per action, then the deadline decides
                        last = f"{act} failed ({type(e).__name__})"
                time.sleep(1.5)
            return say("unknown_screen", last)
        finally:
            for q in owned:
                try:
                    if not q.is_closed():
                        q.close()
                except Exception:  # noqa: BLE001 - closing our own tabs is courtesy
                    pass


def main(argv: List[str]) -> int:
    if argv[:1] == ["drive"]:
        return drive()
    global DRY
    DRY = "--dry-run" in argv
    argv = [x for x in argv if x != "--dry-run"]
    i = argv.index("--account") + 1 if "--account" in argv else 0
    forced = "--force" in argv and 0 < i < len(argv)
    if argv and not forced:
        print("usage: claude-login-renew.py [--dry-run] [--account <email> --force]      (--account --force: renew that account's login now; no arguments: the scheduled run; "
              "--dry-run only says what it would do)", file=sys.stderr)
        return 64
    c = C.city()
    lock = (c / ".gc" / "claude-login-renew.lock") if c and (c / ".gc").is_dir() else state_path().with_suffix(".lock")
    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another run holds the lock - nothing done this time", file=sys.stderr)
        return 2 if forced else 0                              # a forced renewal that did not run is "not renewed", never a quiet 0
    except OSError as e:
        rlog("ERROR", f"cannot take the lock ({type(e).__name__}) - nothing was done")
        return 1
    try:
        return run_once(argv[i].strip().lower()) if forced else housekeeping()
    except Exception as e:  # noqa: BLE001 - a launchd job that crashes silently is the failure this exists to remove
        rlog("ERROR", f"run failed ({type(e).__name__}: {str(e)[:120]})")
        return 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
