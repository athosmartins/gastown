#!/usr/bin/env python3
"""claude-login-renew — ga-xoe5ao.5 (slices 1-2 of 3): renew the login of a Claude account of the mini without calling Athos, and call him ONCE when it cannot.

    claude-login-renew.py --account <email> --force      0 = renewed, 2 = not renewed (the line printed and the log say why)
    claude-login-renew.py                                launches NOTHING: lifts the marks of accounts somebody logged in by hand, retries the pushes not yet delivered

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
repeated); a wall fixed in the BROWSER (CHROME_FIX) is to be looked at again after RECHECK_S (`recheck_at`), a transient failure after RETRY_S (`next_at`),
the 3rd failure in a row is the same mark; a login made by hand (HAND_LOGIN_GAIN_S more life) lifts the mark.
Slice 3 (not here): the forecast / outage triggers that READ `recheck_at` and `next_at`, the launchd plist and the off switch.

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
                       r"(?:solve|complete) the captcha|captcha challenge", re.I)         # visible words of a challenge, not the footer of a page that merely mentions reCAPTCHA
DEVICE_RE = re.compile(r"tap yes|check your (?:phone|device)|security key|passkey|verify it(?:'|’)s you|use your phone|unusual activity", re.I)
CHROME_FIX = ("no_google_session", "needs_password")     # fixed in the BROWSER: the job can see it worked. The others are fixed by a login by hand (the Keychain shows it)
PERMANENT = ("puzzle", "no_google_session", "needs_password", "needs_device", "wrong_account")     # a retry cannot change these: a human can


def rlog(level: str, msg: str) -> None:
    if "sk-ant-" in msg or "authorize?" in msg or "code_challenge" in msg or "state=" in msg:
        msg = "[line withheld: token- or URL-shaped text]"
    line = f"{C._iso(C.now())} pid={os.getpid()} renew {level} {msg}"
    c = C.city()
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
def push(title: str, text: str) -> bool:
    """One `notify -p 4` under notify's STRICT contract (the crew module's push, ga-xoe5ao.4): delivered = exit 0, 10 (held for 07:00) or 11 (same title < 30 min)."""
    n = os.environ.get("CLAUDE_CREW_NOTIFY") or shutil.which("notify")
    if not n:
        rlog("ERROR", f"no notify binary: the push '{title}' could not be sent")
        return False
    env = {**os.environ, "NOTIFY_STRICT_EXIT": "1", "NOTIFY_FORCE_PUSH": "1"}
    try:
        # vazio (nothing printed) → fine, only the exit code counts; falhou/ilegível (cannot run, any exit but 0/10/11) → NOT delivered, said, retried
        r = subprocess.run([n, "-t", title, "-p", "4", f"job falhou: claude-login-renew — {text}"], env=env, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        rlog("ERROR", f"notify could not run ({type(e).__name__}): the push '{title}' was not delivered")
        return False
    if r.returncode not in C.NOTIFY_DELIVERED:
        rlog("ERROR", f"notify exit={r.returncode}: the push '{title}' was not delivered")
        return False
    return True


def state_path() -> Path:
    return Path(os.environ.get("CLAUDE_RENEW_STATE") or DEFAULT_STATE)


def load_state() -> dict:
    # vazio (no file) → a first run; falhou/ilegível (not json, not an object of account records) → an empty state, SAID: marks and tries are lost, a wall may be met once more
    try:
        d = json.loads(state_path().read_bytes().decode())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, RecursionError):
        rlog("WARN", f"the state file {state_path()} is unreadable - starting from an empty state (marks and tries are lost)")
        return {}
    acc = d.get("accounts", {}) if isinstance(d, dict) else None
    if not (isinstance(acc, dict) and all(isinstance(v, dict) for v in acc.values())):      # valid json of the wrong SHAPE is the same unreadable state, not a crash on every run
        rlog("WARN", f"the state file {state_path()} is unreadable (not an object of account records) - starting from an empty state (marks and tries are lost)")
        return {}
    return d


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


def holder_of_default() -> Optional[str]:
    crew, _ = C.load_state()
    h = crew.get("current")
    return h if isinstance(h, str) else None


def survey(email: str, holder: Optional[str], t: float) -> dict:
    """best_left: seconds to the end of the best refresh token `email` has (None = no end recorded anywhere); unread: an item that could not be read."""
    best, unread = None, False
    for svc in list(C.source_services(email)) + ([C.DEFAULT_SERVICE] if email == holder else []):
        s, _, b = C.kc_read(svc)
        # vazio (missing item, an item with no login object) → says nothing; falhou/ilegível (locked keychain, crashed security: 'unknown' with no blob) → NOT judged this run
        if s == "unknown" and b is None:
            unread = True
        elif s == "ok" and b:
            left = C._ms_left(b["claudeAiOauth"], "refreshTokenExpiresAt", t)
            if left is not None:
                best = left if best is None else max(best, left)
    return {"best_left": best, "unread": unread}


def release_marks(st: dict, holder: Optional[str], t: float) -> None:
    """A mark is lifted when somebody logged the account in by hand: its best login now has HAND_LOGIN_GAIN_S more life than when it was marked,
    or it now has a login with a recorded end where the mark found none."""
    for email, a in list((st.get("accounts") or {}).items()):
        mark = a.get("infeasible")
        if not isinstance(mark, dict):
            continue
        v, was = survey(email, holder, t), mark.get("left")
        # vazio (the item says nothing now) / falhou (cannot be read now) → the mark stands, the inert side; only a MEASURED login lifts it
        if v["unread"] or v["best_left"] is None:
            continue
        if was is None or (isinstance(was, (int, float)) and not isinstance(was, bool) and v["best_left"] >= was + HAND_LOGIN_GAIN_S):
            a.pop("infeasible")
            a.pop("tries", None)
            a.pop("next_at", None)
            rlog("INFO", f"{email}: logged in by hand - the mark is lifted, back in rotation")


def step_text(email: str, verdict: str, step: str) -> str:
    chrome = ("sign this Google account in ONCE in the automation Chrome on the mini (profile ~/.chrome-cdp, `cdp status`; password and 2-step by you, "
              "nothing passes through an agent). The job looks again within a day and, from then on, the renewal is automatic")
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
    return f"{email} cannot be renewed automatically ({verdict}): {why} Its login ends in the next days."


def tell(st: dict, email: str, t: float) -> None:
    """ONE push per mark: retried every PUSH_RETRY_S while notify does not deliver it, never again once it did."""
    mark = acct_rec(st, email).get("infeasible")
    if not isinstance(mark, dict) or mark.get("pushed") or t < C._num(mark.get("next_push")):
        return
    mark["next_push"] = t + PUSH_RETRY_S
    if push(f"Relogin automatico impossivel: {email}", step_text(email, mark.get("verdict", ""), str(mark.get("step") or ""))):
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
    rlog("WARN", f"{email}: marked 'inviavel por automacao' ({verdict}: {step}) - one push; " + (f"looked at again in {RECHECK_S // 3600} h" if verdict in CHROME_FIX else "no more tries until it is logged in by hand"))


def run_account(st: dict, holder: Optional[str], email: str, reason: str, t: float) -> Tuple[str, str, Optional[dict]]:
    """One attempt and what it leaves in the state: a proof clears the account's tries and mark; a wall marks it; a transient failure counts."""
    a = acct_rec(st, email)
    left = survey(email, holder, t)["best_left"]
    rlog("INFO", f"renewing {email} ({reason}): claude auth login in {acct_dir(email)}")
    verdict, step, proof = attempt(email, reason, t)
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


def run_once(email: str) -> int:
    """Renew `email` now. 0 = renewed; 2 = not (a wall the job does not get around, a failed try, an account with no config dir): the line says which."""
    if email not in C.accounts() or not acct_dir(email):
        print(f"{email}: not one of the accounts with a config dir ('no config dir' = nothing to log into) - nothing done", file=sys.stderr)
        return 2
    t, st = C.now(), load_state()
    verdict, step, proof = run_account(st, holder_of_default(), email, "forced", t)
    if proof:
        b, a = proof["before"], proof["after"]
        line = (f"{email}: renewed; item {proof['svc']}: access {b['afp'] if b else 'none'} -> {a['afp']}, refresh {b['rfp'] if b else 'none'} -> {a['rfp']}, ends {a['rexp']}"
                + (" (owner unverified: the profile could not say whose the login is)" if proof["owner_unverified"] else ""))
    else:
        line = f"{email}: NOT renewed ({verdict}: {step})"
    errs = [save(st)]                                          # the mark is written BEFORE the push: a crash in between re-sends it, it does not forget the wall
    tell(st, email, t)                                         # ... and a state that cannot be written never keeps Athos from hearing about a wall
    errs.append(save(st))
    mark, tries = acct_rec(st, email).get("infeasible"), acct_rec(st, email).get("tries")
    if not proof and not isinstance(mark, dict) and tries:
        line += f" - failed try {int(C._num(tries))} of {MAX_TRIES}"
    if isinstance(mark, dict):
        again = f"looked at again in {RECHECK_S // 3600} h" if mark.get("verdict") in CHROME_FIX else "no automatic retry until it is logged in by hand"
        line += (f" - marked 'inviavel por automacao' ({again}); by hand: {C.relogin_cmd(email)}. "
                 + ("Athos was told (one push)." if mark.get("pushed") else f"The push was NOT delivered: the bare run retries it every {PUSH_RETRY_S // 60} min."))
    err = next((e for e in errs if e), None)
    if err:
        rlog("ERROR", f"{email}: the state could not be written ({type(err).__name__}): this run's marks and tries are lost")
        line += f" | the state file could not be written ({type(err).__name__}): this run's marks, tries and push are NOT recorded"
    rlog("INFO" if proof else "WARN", line)
    print(line)
    return 0 if proof else 2


def housekeeping() -> int:
    """No account named: launches nothing. Lifts the marks of accounts somebody logged in by hand and retries the pushes that were not delivered."""
    t, st = C.now(), load_state()
    release_marks(st, holder_of_default(), t)
    for email in list(st.get("accounts") or {}):
        tell(st, email, t)
    if st.get("accounts"):
        publish_state(st)
    return 0


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
        return "click_continue" if "continue" in buttons else "wait"
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
                            pg.get_by_role("button", name=re.compile(r"^continue$", re.I)).first.click(timeout=5000)
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
    i = argv.index("--account") + 1 if "--account" in argv else 0
    forced = "--force" in argv and 0 < i < len(argv)
    if argv and not forced:
        print("usage: claude-login-renew.py [--account <email> --force]      (renew that account's login now; no arguments = lift the marks, retry the pushes)", file=sys.stderr)
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
