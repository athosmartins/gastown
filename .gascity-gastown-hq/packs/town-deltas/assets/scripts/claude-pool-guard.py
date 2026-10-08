#!/usr/bin/env python3
"""claude-pool-guard — ga-8hcnvb.3: the safety net under claude-pool-account.py (ga-8hcnvb.1).

The 1a daemon moves the pool between accounts by rewriting ONE Keychain item that claude reads through an undocumented variable
(CLAUDE_SECURESTORAGE_CONFIG_DIR). Two things can go wrong silently, and this guard is what makes them loud:

  1. DIVERGENCE. The account the pool really uses (the credential in the pool item) is not the account the decision says
     (claude_pool_current_account.json: `current` + `fingerprint`). Persisting for DEBOUNCE_S (120 s: the daemon writes the item and
     then the file, so a short disagreement is normal) -> ONE push to Athos naming both accounts by e-mail + 8-hex fingerprint, repeated
     every 6 h while it lasts, nothing when it is fixed. The guard never corrects it: that is the daemon's job.
  2. THE DAEMON'S LIVENESS: a run that gets to the end without logging an ERROR stamps <city>/.gc/claude-pool-account.heartbeat. No such run
     for 10 min -> one push. (The exit status cannot say it: a run that found no accounts library exits 0 too.)

THREE ANSWERS, never two. Every check says yes / no / could not tell, and "could not tell" never acts: a locked Keychain, an unreadable
file, a vault that does not answer is not a divergence and not a dead daemon. It is reported (as "guard blind" after 30 min) and changes nothing.

Tokens: the guard holds the pool item's credential in memory only to take its sha256[:8]. It never puts a credential in argv, env, a log,
its state file, an alert or an error message.
Alerts carry e-mails and 8-hex fingerprints only, and are refused if they contain anything token-shaped.

Usage:  claude-pool-guard.py run-once            one pass (launchd, every 60 s, single instance)
KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the guard does nothing (the operator turned the mechanism off).
SEAMS (tests): CLAUDE_POOL_GUARD_STATE, CLAUDE_POOL_NOTIFY_CMD, CLAUDE_POOL_GUARD_DEBOUNCE_S (<= 240), and the daemon's own:
CLAUDE_POOL_STATE, CLAUDE_POOL_CRED_DIR, CLAUDE_POOL_ACCOUNTS_LIB, CLAUDE_POOL_NOW, CLAUDE_POOL_DAEMON.
"""
from __future__ import annotations

import errno
import fcntl
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

DEFAULT_GUARD_STATE = "/Users/athos/shared/data/claude_pool_guard.json"
SCHEMA = 1
DEBOUNCE_S = 120                 # persistent divergence before the alert; with a 60 s tick the alert is out in ~3 min, inside the 5 min budget
MAX_DEBOUNCE_S = 240             # an env seam must not be able to push the alert past the 5 min budget
REMIND_S = 6 * 3600              # an open episode is repeated this often, never more
BLIND_S = 1800                   # 'could not tell' for this long is itself reported (once)
HEARTBEAT_STALE_S = 600          # the daemon runs every 60 s: 10 min without a clean run is not a slow run
LIVENESS_GAP_S = 300             # two looks at the daemon further apart than this: the guard was not looking in between (asleep, unloaded, off, stood down)
FP_RE = re.compile(r"[0-9a-f]{8}")
FP_MAP_MAX = 20

D = None   # the daemon module (claude-pool-account.py), loaded by main(): ONE definition of how the pool item is named and read


def load_daemon():
    p = Path(os.environ.get("CLAUDE_POOL_DAEMON") or Path(__file__).resolve().with_name("claude-pool-account.py"))
    spec = importlib.util.spec_from_file_location("claude_pool_account_ext", str(p))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for need in ("disabled", "HEARTBEAT_FILE", "read_item_token", "fingerprint", "login_name", "valid_user", "city", "now", "_iso",
                 "state_path", "CLOCK_SKEW_S"):
        if not hasattr(mod, need):
            raise ImportError(f"{p.name} lacks {need} (the guard needs the ga-8hcnvb.3 version of the daemon)")
    return mod


# ── log (never a token) ───────────────────────────────────────────────────────────────────────────
def glog(level: str, msg: str) -> None:
    if "sk-ant-" in msg:
        msg = "[line withheld: token-shaped text]"
    line = f"{D._iso(D.now())} pid={os.getpid()} guard {level} {msg}"
    c = D.city()
    try:
        if c and (c / ".gc" / "logs").is_dir():
            with open(c / ".gc" / "logs" / "claude-pool-guard.log", "a") as f:
                f.write(line + "\n")
            return
    except OSError:
        pass
    print(line, file=sys.stderr)


# ── the guard's own state ──────────────────────────────────────────────────────────────────────────
def gstate_path() -> Path:
    return Path(os.environ.get("CLAUDE_POOL_GUARD_STATE") or DEFAULT_GUARD_STATE)


def load_gstate() -> Optional[dict]:
    """{} = no state yet (absent, or corrupt and moved aside). None = there but unreadable now: do not act on what cannot be seen."""
    p = gstate_path()
    try:
        raw = p.read_bytes()
    except FileNotFoundError:
        return {}
    except OSError as e:
        glog("ERROR", f"guard state {p} unreadable ({type(e).__name__}) - refusing to run blind about what was already alerted")
        return None
    try:
        d = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        d = None
    if isinstance(d, dict):
        return d
    aside = p.with_name(p.name + f".corrupt.{int(D.now())}")
    try:
        os.replace(p, aside)
    except OSError as e:
        glog("ERROR", f"guard state {p} is corrupt and could not be moved aside ({type(e).__name__}) - refusing to run")
        return None
    glog("WARN", f"guard state {p} is not a JSON object - moved to {aside.name}, starting empty")
    return {}


def save_gstate(gs: dict) -> None:
    p = gstate_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    gs["schema"] = SCHEMA
    gs["updated"] = D._iso(D.now())
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(gs, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, p)


def _dict(gs: dict, key: str) -> dict:
    v = gs.get(key)
    if not isinstance(v, dict):
        v = {}
        gs[key] = v
    return v


def _num(v) -> Optional[float]:
    """A time or a duration read from a file. Missing, not a number, NaN or +-infinity (json.loads accepts NaN and Infinity; the arithmetic on
    them raises or never compares true) -> None, which every caller reads as 'no usable value' (never as 0, never as a time)."""
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


# ── alerts ─────────────────────────────────────────────────────────────────────────────────────────
def debounce_s() -> float:
    try:
        v = float(os.environ.get("CLAUDE_POOL_GUARD_DEBOUNCE_S", ""))
    except ValueError:
        return float(DEBOUNCE_S)
    return max(0.0, min(v, float(MAX_DEBOUNCE_S)))


def send_alert(title: str, msg: str, prio: int = 4, force: bool = True, secrets_in_memory: Tuple[str, ...] = ()) -> bool:
    """True = the push was accepted (or already went out / is held until 7h by notify's quiet hours); False = it did not go: the caller
    leaves the episode un-alerted and the next tick tries again. The text is refused if anything token-shaped (or a credential the
    guard holds) is in it.
    rc 11 means notify dropped it because a push with the same TITLE went out in the last 30 min (whatever the body says): it is counted
    as delivered here, so two different conditions must never share a title - what makes a condition different goes IN the title.
    rc 12 is notify's digest route (a row goes to its history, nothing to the phone). For a quiet notice (force=False) the digest is where
    it is meant to go, so 12 is delivered; for a FORCED alert it is not: notify's router and its policy pass a forced push straight through
    (classify_route_detail -> "push forced", athos_policy_wa_hlyupm leaves it alone), so the digest legs are never reached and the only
    12 left is the per-source / global rate cap - nothing reached the phone: not delivered, retried."""
    for text in (title, msg):
        if "sk-ant-" in text or any(s and s in text for s in secrets_in_memory):
            glog("ERROR", "alert REFUSED: it contained token-shaped text (a bug); nothing was sent")
            return False
    cmd = os.environ.get("CLAUDE_POOL_NOTIFY_CMD") or "notify"
    env = dict(os.environ)
    env["NOTIFY_STRICT_EXIT"] = "1"      # a distinct exit status per outcome (10 held till 7h, 11 deduped, 12 digest/cap, ...)
    if force:
        env["NOTIFY_FORCE_PUSH"] = "1"   # without it notify routes an unknown source to the muted digest topic (allowlist, wa-f53j6)
    try:
        r = subprocess.run([cmd, "-t", title, "-p", str(prio), msg], env=env, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        glog("ERROR", f"notify could not run ({type(e).__name__}): alert '{title}' NOT sent, will retry")
        return False
    if r.returncode in (0, 10, 11) or (r.returncode == 12 and not force):
        glog("INFO", f"alert sent: {title} (notify rc={r.returncode})" + (" - filed in the digest, as a quiet notice is meant to be" if r.returncode == 12 else ""))
        return True
    glog("ERROR", f"notify rc={r.returncode}: alert '{title}' NOT delivered, will retry")
    return False


def name_fp(email: Optional[str], fp: Optional[str]) -> str:
    return f"{email} (fp {fp})" if email and fp else (f"conta não identificada (fp {fp})" if fp else "nenhuma")


# ── who is this fingerprint? ───────────────────────────────────────────────────────────────────────
def whois(fp: str) -> int:
    """Child process of `lookup_vault`: hashes the vault's keys (in this process's memory only) and prints the e-mail whose key has
    this fingerprint. 0 found / 3 none of the accounts has it / 4 could not tell (some account's key could not be read)."""
    lib = D.load_accounts_lib()
    if lib is None:
        return 4
    try:
        emails = [e for e in lib.ordem_das_contas() if isinstance(e, str) and e]
    except Exception:  # noqa: BLE001
        return 4
    if not emails:
        return 4
    unread = 0
    for e in emails:
        tok = lib.token_da_conta(e)
        if not tok:
            unread += 1
        elif D.fingerprint(tok) == fp:
            print(e)
            return 0
    return 4 if unread else 3


def lookup_vault(fp: str) -> Tuple[str, Optional[str]]:
    """('found', email) | ('none', None) | ('unknown', None). A child process, so a vault that hangs costs a timeout, not the alert."""
    try:
        r = subprocess.run([sys.executable, str(Path(__file__).resolve()), "_whois", fp], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return "unknown", None
    out = (r.stdout or "").strip()
    if r.returncode == 0 and out and "@" in out:
        return "found", out.splitlines()[0]
    return ("none", None) if r.returncode == 3 else ("unknown", None)


def who_is(fp: str, gs: dict) -> Tuple[Optional[str], str]:
    """(email or None, how it is said). Learned decisions first (free); the vault only when an alert is about to go out."""
    known = _dict(gs, "fp_map").get(fp)
    if isinstance(known, str) and known:
        return known, "known"
    how, email = lookup_vault(fp)
    if how == "found":
        _dict(gs, "fp_map")[fp] = email
        return email, "vault"
    return None, ("not-among-the-vault-keys" if how == "none" else "vault-unreadable")


def learn(gs: dict, email: Optional[str], fp: Optional[str]) -> None:
    if isinstance(email, str) and email and isinstance(fp, str) and FP_RE.fullmatch(fp):
        m = _dict(gs, "fp_map")
        m[fp] = email
        while len(m) > FP_MAP_MAX:
            m.pop(next(iter(m)))


# ── 1. divergence ──────────────────────────────────────────────────────────────────────────────────
def read_decision() -> Tuple[str, dict]:
    """('absent'|'ok'|'unreadable', decision). Read-only: the daemon's state loader moves a corrupt file aside, and that is a write."""
    p = D.state_path()
    try:
        raw = p.read_bytes()
    except FileNotFoundError:
        return "absent", {}
    except OSError:
        return "unreadable", {}
    try:
        d = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        return "unreadable", {}
    return ("ok", d) if isinstance(d, dict) else ("unreadable", {})


def judge_divergence(user: str) -> Tuple[str, dict]:
    """('same'|'diverged'|'inactive'|'unknown', facts). facts: why, exp_email, exp_fp, in_fp, token (only for the in-memory refusal list)."""
    dstat, dec = read_decision()
    istat, tok = D.read_item_token(user)
    if dstat == "unreadable":
        return "unknown", {"why": "the decision file cannot be read"}
    if istat == "unknown":
        return "unknown", {"why": "the pool item cannot be read (locked Keychain or security failing)"}
    cur = dec.get("current") if dstat == "ok" else None
    exp_fp = dec.get("fingerprint") if dstat == "ok" else None
    has_dec = isinstance(cur, str) and bool(cur.strip())
    if has_dec and not (isinstance(exp_fp, str) and FP_RE.fullmatch(exp_fp)):
        return "unknown", {"why": "the decision carries no fingerprint to compare with"}
    in_fp = D.fingerprint(tok) if istat == "ok" and tok else None
    facts = {"exp_email": cur if has_dec else None, "exp_fp": exp_fp if has_dec else None, "in_fp": in_fp, "token": tok or "", "item": istat}
    if not has_dec and istat == "missing":
        return "inactive", facts          # never activated (or switched off): nothing to compare
    if has_dec and istat == "ok" and in_fp == exp_fp:
        return "same", facts
    if has_dec and istat == "missing":
        facts["why"] = "o item do pool não existe: sessões novas caem no login ambiente"
    elif istat == "ok" and not tok:
        facts["why"] = "o item do pool existe mas não tem credencial"
    elif has_dec:
        facts["why"] = "o item do pool guarda outra credencial"
    else:
        facts["why"] = "o item do pool existe mas não há decisão publicada"
    return "diverged", facts


def check_divergence(gs: dict, t: float, user: str) -> None:
    verdict, f = judge_divergence(user)
    ep = gs.get("divergence") if isinstance(gs.get("divergence"), dict) else None
    if verdict == "unknown":
        blind(gs, t, "divergence", f["why"])
        return
    unblind(gs, "divergence")
    if verdict in ("same", "inactive"):
        if ep:
            glog("INFO", f"divergence over after {int(t - (_num(ep.get('since')) or t))}s: the pool item matches the decision again - no further alerts")
        gs["divergence"] = None
        if verdict == "same":
            learn(gs, f["exp_email"], f["exp_fp"])
        return
    # diverged (nothing is learned here: a decision that disagrees with the item is no evidence of whose key the item holds)
    if not ep:
        ep = {"since": t, "alerted_at": None}
        gs["divergence"] = ep
        glog("WARN", f"divergence seen: expected fp={f['exp_fp']} item fp={f['in_fp']} ({f['why']}); alert if it lasts {int(debounce_s())}s")
    ep.update({"exp_email": f["exp_email"], "exp_fp": f["exp_fp"], "in_fp": f["in_fp"], "why": f["why"], "last_seen": t})
    since = _num(ep.get("since")) or t
    last = _num(ep.get("alerted_at"))
    if t - since < debounce_s():
        return
    if last is not None and t - last < REMIND_S:
        return
    exp = name_fp(f["exp_email"], f["exp_fp"]) if f["exp_fp"] else "nenhuma (sem decisão)"
    if f["in_fp"]:
        email, how = who_is(f["in_fp"], gs)
        use = name_fp(email, f["in_fp"])
        if not email:
            use += " - " + ("não é nenhuma das chaves do cofre" if how == "not-among-the-vault-keys" else "o cofre não respondeu")
    else:
        use = "nenhuma (item ausente)" if f.get("item") == "missing" else "item sem credencial (vazio)"
    mins = int((t - since) // 60)
    again = "Lembrete: " if last is not None else ""
    msg = (f"{again}A regra manda o pool usar {exp}, mas ele está em {use} há {mins} min ({f['why']}). "
           f"Sem correção automática aqui; reavisa a cada 6 h enquanto durar.")
    title = f"Pool Claude: conta em uso diverge da regra (regra {f['exp_fp'] or 'sem decisão'}, em uso {f['in_fp'] or 'nenhuma'})"
    if send_alert(title, msg, 4, True, (f.get("token") or "",)):
        ep["alerted_at"] = t


# ── 'could not tell' is reported, never acted on ───────────────────────────────────────────────────
def blind(gs: dict, t: float, what: str, why: str, since: Optional[float] = None) -> None:
    """`what` could not be verified. After BLIND_S of that, ONE alert says so (repeated every REMIND_S). `since`: when the not-knowing really
    began, if the caller has been counting (so the 30 minutes are not counted twice)."""
    b = _dict(gs, "blind")
    e = b.get(what) if isinstance(b.get(what), dict) else None
    if not e:
        e = {"since": since if since is not None else t, "alerted_at": None}
        b[what] = e
        glog("WARN", f"cannot verify {what}: {why} - nothing changed")
    e["why"] = why
    since = _num(e.get("since")) or t
    last = _num(e.get("alerted_at"))
    if t - since < BLIND_S or (last is not None and t - last < REMIND_S):
        return
    if send_alert(f"Pool Claude: guarda sem enxergar ({what})",
                  f"Não consigo verificar '{what}' há {int((t - since) // 60)} min ({why}). Nada foi alterado.", 4, True):
        e["alerted_at"] = t


def unblind(gs: dict, what: str) -> None:
    b = gs.get("blind")
    if isinstance(b, dict) and b.pop(what, None) is not None:
        glog("INFO", f"can verify {what} again")


def _probe(f, p: Path) -> Optional[bool]:
    """f(p) for a Path predicate (is_dir, is_symlink, exists), or None when it cannot be told: on Python 3.9 they raise PermissionError for
    anything but 'not there', and a traceback is no answer. Callers choose what 'cannot tell' means - always the side that changes nothing."""
    try:
        return bool(f(p))
    except OSError:
        return None


# ── 2. the daemon's liveness ───────────────────────────────────────────────────────────────────────
def read_heartbeat(t: float) -> Tuple[str, Optional[float]]:
    """('absent'|'ok'|'unreadable', epoch). Only a file that is NOT THERE means 'no clean run on record'. One that cannot be read, has no
    usable epoch or is stamped in the future (a stuck clock would hide a dead daemon for as long as it lasts) is 'cannot tell'."""
    c = D.city()
    if not c:
        return "unreadable", None
    try:
        raw = (c / ".gc" / D.HEARTBEAT_FILE).read_text()
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unreadable", None
    try:
        epoch = _num(json.loads(raw).get("epoch"))
    except (ValueError, AttributeError, RecursionError):
        return "unreadable", None
    if epoch is None or epoch > t + D.CLOCK_SKEW_S:
        return "unreadable", None
    return "ok", epoch


def check_daemon_alive(gs: dict, t: float, user: str) -> None:
    """The daemon's silence is judged only over time the guard was LOOKING. A stamp that went stale while the guard was not looking (its own
    absence: a reboot, a sleep, launchd unloaded) or while the daemon was stood down on purpose (the operator's switches: the real
    daemon stamps nothing then) is not evidence of a death. So: `watch_since` is when this unbroken stretch of looking began (reset whenever
    two looks are more than LIVENESS_GAP_S apart) and the silence is counted from max(last stamp, watch_since)."""
    hstat, last = read_heartbeat(t)
    if hstat == "unreadable":
        blind(gs, t, "daemon-heartbeat", "the daemon's heartbeat file cannot be read or holds no usable time")
        return
    unblind(gs, "daemon-heartbeat")
    dstat, _ = read_decision()
    istat, _tok = D.read_item_token(user)
    if last is None and dstat == "absent" and istat == "missing":
        gs["daemon"] = None      # never activated: nothing to be dead
        return
    if last is None and dstat != "ok" and istat != "ok":
        return                   # no heartbeat, and whether the daemon was ever switched on cannot be told (Keychain locked / decision unreadable): no verdict
    d = _dict(gs, "daemon")
    prev, watch = _num(d.get("checked_at")), _num(d.get("watch_since"))
    if prev is not None and not (0 <= t - prev <= LIVENESS_GAP_S):
        watch = t                # the guard was not looking in between: what went stale meanwhile proves nothing
    elif watch is None or prev is None:
        watch = t if last is None else last   # the first look ever: with a stamp on record its age is the evidence, with none the count starts now
    d["watch_since"] = watch
    d["checked_at"] = t
    if last is not None and t - last < HEARTBEAT_STALE_S:
        if d.get("stale_since") is not None:
            glog("INFO", "the daemon completes runs again")
        d["stale_since"] = None
        d["alerted_at"] = None
        return
    ref = max(last, watch) if last is not None else watch    # no clean run on record at all: count from when the guard began to look
    if t - ref < HEARTBEAT_STALE_S:
        return                   # not looked at for long enough to call it silent (an open episode is left as it is: this is not a recovery either)
    mins = int((t - ref) // 60)
    when = D._iso(last) if last else None
    if d.get("stale_since") is None:
        d["stale_since"] = t
        glog("WARN", f"the daemon has not completed a clean run in the {mins} min the guard has been looking (last: {when or 'never'}); see claude-pool-account.log")
    a = _num(d.get("alerted_at"))
    if a is None or t - a >= REMIND_S:
        # the last stamp is in the title: a daemon that recovers and stops again is a new episode, and notify drops a repeated title within 30 min
        if send_alert(f"Pool Claude: o daemon de troca não está fechando rodadas (última: {when[:16] + 'Z' if when else 'nunca'})",
                      f"Nenhuma rodada limpa (sem erro) do daemon nos últimos {mins} min em que o guarda acompanhou (última: {when or 'nunca'}). "
                      f"O motivo está em claude-pool-account.log. O pool não troca de conta sozinho enquanto isso.", 4, True):
            d["alerted_at"] = t


# ── one pass ───────────────────────────────────────────────────────────────────────────────────────
def run_once() -> int:
    """The launchd tick: quiet (it logs), rc 0 when it has nothing to do."""
    def not_run(why: str, quiet_rc: int) -> int:
        glog("INFO" if quiet_rc == 0 else "ERROR", why)
        return quiet_rc
    off = D.disabled()
    if off:
        return not_run(f"disabled by {off} - nothing done", 0)
    c = D.city()
    lp = c / ".gc" / "claude-pool-guard.lock" if c and _probe(Path.is_dir, c / ".gc") else None
    if lp is None:
        return not_run("no usable GC_CITY_PATH/.gc - cannot take the single-instance lock, refusing to run unlocked", 1)
    try:
        lock_fd = open(lp, "w")
    except OSError as e:
        return not_run(f"cannot open the lock file {lp} ({type(e).__name__}) - refusing to run unlocked", 1)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return not_run("another guard run holds the lock (the launchd tick, most likely): try again in a minute", 0)
        return not_run(f"flock failed (errno={e.errno}) - refusing to run unlocked", 1)
    user = D.login_name()
    if not D.valid_user(user):
        return not_run("the login name is empty or not a plain name - refusing to build a Keychain command from it", 1)
    gs = load_gstate()
    if gs is None:
        return not_run("the guard's state file could not be loaded (see the guard log)", 1)
    t = D.now()
    steps = [("divergence", lambda: check_divergence(gs, t, user)), ("liveness", lambda: check_daemon_alive(gs, t, user))]
    rc = 0
    for name, fn in steps:
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - one failing check must not take the others down; the TYPE only, never a message
            glog("ERROR", f"unhandled {type(e).__name__} in {name}")
            rc = 1
    try:
        save_gstate(gs)
    except Exception as e:  # noqa: BLE001
        glog("ERROR", f"guard state NOT saved ({type(e).__name__}): the next run may repeat an alert")
        rc = 1
    return rc


def main(argv: List[str]) -> int:
    global D
    cmd = argv[1] if len(argv) > 1 else "run-once"
    try:
        D = load_daemon()
    except Exception as e:  # noqa: BLE001
        print(f"claude-pool-guard: cannot load the daemon module ({type(e).__name__}): {e}", file=sys.stderr)
        return 1
    if cmd == "_whois" and len(argv) == 3 and FP_RE.fullmatch(argv[2]):
        return whois(argv[2])
    if cmd == "run-once":
        try:
            return run_once()
        except Exception as e:  # noqa: BLE001 - last resort: the TYPE only
            glog("ERROR", f"unhandled {type(e).__name__} in {cmd}")
            return 1
    print("usage: claude-pool-guard.py run-once", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
