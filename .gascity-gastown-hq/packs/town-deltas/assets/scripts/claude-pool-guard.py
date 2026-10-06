#!/usr/bin/env python3
"""claude-pool-guard — ga-8hcnvb.3: the safety net under claude-pool-account.py (ga-8hcnvb.1).

The 1a daemon moves the pool between accounts by rewriting ONE Keychain item that claude reads through an undocumented variable
(CLAUDE_SECURESTORAGE_CONFIG_DIR). Two things can go wrong silently, and this guard is what makes them loud:

  1. DIVERGENCE. The account the pool really uses (the credential in the pool item) is not the account the decision says
     (claude_pool_current_account.json: `current` + `fingerprint`). Persisting for DEBOUNCE_S (120 s: the daemon writes the item and
     then the file, so a short disagreement is normal) -> ONE push to Athos naming both accounts by e-mail + 8-hex fingerprint, repeated
     every 6 h while it lasts, nothing when it is fixed. The guard never corrects it: that is the daemon's job.
  2. A CLAUDE RELEASE THAT CHANGED THE INTERNALS. Whenever `claude --version` differs from the last version tested, a per-version
     self-test runs: claude is pointed at a scratch item (fake credential, scratch directory - never the pool item) and asked
     `claude auth status --json` (local: no inference, no network). It must be logged in while the item is there and NOT logged in once the
     item is gone. If it is not -> the mechanism does not work on this version -> the guard writes <city>/.gc/pool-account-degraded.
     The daemon then does nothing and claude-lowprio.sh stops pointing new pool launches at the item: they start on the ambient login.
     Nothing is deleted and no session is interrupted (a live session keeps the last account written, a valid login). One push says
     "auto-switch is OFF". The self-test is repeated every 30 min while degraded and on every new version; when it passes the marker is
     removed and a quiet notice says so.
  + the daemon's liveness: a run that gets to the end without logging an ERROR stamps <city>/.gc/claude-pool-account.heartbeat. No such run
    for 10 min -> one push. (The exit status cannot say it: a run that found no accounts library exits 0 too.)

THREE ANSWERS, never two. Every check says yes / no / could not tell, and "could not tell" never acts: a locked Keychain, an unreadable
file, a claude that timed out is not a divergence and not a failure. It is reported (as "guard blind" after 30 min) and changes nothing.
The test result is pass / fail / inconclusive; only a fail - twice in a row - degrades.

Tokens: the guard holds the pool item's credential in memory only to take its sha256[:8]. It never puts a credential in argv, env, a log,
its state file, an alert or an error message; the fake credential of the self-test goes to the Keychain on `security -i`'s STDIN.
Alerts carry e-mails and 8-hex fingerprints only, and are refused if they contain anything token-shaped.

Usage:  claude-pool-guard.py run-once            one pass (launchd, every 60 s, single instance)
        claude-pool-guard.py status [--json]     the per-version results + open episodes (reads the state file; no side effect)
        claude-pool-guard.py selftest            run the per-version self-test now, whatever was recorded, and act on the result
KNOBS: GC_POOL_ACCOUNT=0 or <city>/.gc/no-pool-account -> the guard does nothing (the operator turned the mechanism off).
SEAMS (tests): CLAUDE_POOL_GUARD_STATE, CLAUDE_POOL_GUARD_SCRATCH, CLAUDE_POOL_NOTIFY_CMD, CLAUDE_POOL_GUARD_DEBOUNCE_S (<= 240),
CLAUDE_POOL_GUARD_RETRY_WAIT_S, CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S, CLAUDE_POOL_GUARD_FAULT (remove|rename: a drill that makes the self-test see the credential removed or
renamed from claude's side), GC_LOWPRIO_CLAUDE_BIN (the claude the pool runs), and the daemon's own: CLAUDE_POOL_STATE,
CLAUDE_POOL_CRED_DIR, CLAUDE_POOL_ACCOUNTS_LIB, CLAUDE_POOL_NOW, CLAUDE_POOL_DAEMON.
"""
from __future__ import annotations

import errno
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

DEFAULT_GUARD_STATE = "/Users/athos/shared/data/claude_pool_guard.json"
SCHEMA = 1
DEBOUNCE_S = 120                 # persistent divergence before the alert; with a 60 s tick the alert is out in ~3 min, inside the 5 min budget
MAX_DEBOUNCE_S = 240             # an env seam must not be able to push the alert past the 5 min budget
REMIND_S = 6 * 3600              # an open episode is repeated this often, never more
BLIND_S = 1800                   # 'could not tell' for this long is itself reported (once)
HEARTBEAT_STALE_S = 600          # the daemon runs every 60 s: 10 min without a clean run is not a slow run
SELFTEST_RETRY_S = 1800          # while degraded: try the self-test again this often
INCONCLUSIVE_RETRY_S = 300       # an inconclusive self-test is repeated this often
FP_RE = re.compile(r"[0-9a-f]{8}")
VERSION_RE = re.compile(r"\d+\.\d+\.\d+[0-9A-Za-z.+-]*")
SCRATCH_NAME = "claude-pool-guard-scratch"
PLAIN_ITEM = "Claude Code-credentials"   # Mayor's and the crews' login item: never touched, never even named in a command here
FP_MAP_MAX = 20

D = None   # the daemon module (claude-pool-account.py), loaded by main(): ONE definition of how the pool item is named and read


def load_daemon():
    p = Path(os.environ.get("CLAUDE_POOL_DAEMON") or Path(__file__).resolve().with_name("claude-pool-account.py"))
    spec = importlib.util.spec_from_file_location("claude_pool_account_ext", str(p))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for need in ("operator_off", "degraded_marker", "DEGRADED_MARKER", "HEARTBEAT_FILE", "read_item_token", "item_service",
                 "fingerprint", "login_name", "valid_user", "city", "now", "_iso", "POOL_ITEM_RE", "EXPIRES_AT_MS", "state_path"):
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
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


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
    guard holds) is in it."""
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
    if r.returncode in (0, 10, 11):
        glog("INFO", f"alert sent: {title} (notify rc={r.returncode})")
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
    facts = {"exp_email": cur if has_dec else None, "exp_fp": exp_fp if has_dec else None, "in_fp": in_fp, "token": tok or ""}
    if not has_dec and istat == "missing":
        return "inactive", facts          # never activated (or switched off): nothing to compare
    if has_dec and istat == "ok" and in_fp == exp_fp:
        return "same", facts
    if has_dec and istat == "missing":
        facts["why"] = "o item do pool não existe: sessões novas caem no login ambiente"
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
        use = "nenhuma (item ausente)"
    mins = int((t - since) // 60)
    again = "Lembrete: " if last is not None else ""
    msg = (f"{again}A regra manda o pool usar {exp}, mas ele está em {use} há {mins} min ({f['why']}). "
           f"Sem correção automática aqui; reavisa a cada 6 h enquanto durar.")
    if send_alert("Pool Claude: conta em uso diverge da regra", msg, 4, True, (f.get("token") or "",)):
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
    if send_alert("Pool Claude: guarda sem enxergar",
                  f"Não consigo verificar '{what}' há {int((t - since) // 60)} min ({why}). Nada foi alterado.", 4, True):
        e["alerted_at"] = t


def unblind(gs: dict, what: str) -> None:
    b = gs.get("blind")
    if isinstance(b, dict) and b.pop(what, None) is not None:
        glog("INFO", f"can verify {what} again")


# ── 2. the per-version self-test ───────────────────────────────────────────────────────────────────
def claude_binary() -> Optional[str]:
    return shutil.which(os.environ.get("GC_LOWPRIO_CLAUDE_BIN") or "claude")   # the binary the pool's wrapper execs


def claude_version(binary: str) -> Optional[str]:
    try:
        r = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=20, check=False,
                           env={"HOME": os.environ.get("HOME", ""), "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    except (OSError, subprocess.SubprocessError):
        return None
    m = VERSION_RE.search(r.stdout or "") if r.returncode == 0 else None
    return m.group(0) if m else None


def scratch_dir() -> Path:
    return Path(os.environ.get("CLAUDE_POOL_GUARD_SCRATCH") or (Path.home() / ".gastown" / SCRATCH_NAME))


def scratch_svc(secdir: str) -> str:
    return "Claude Code-credentials-" + hashlib.sha256(secdir.encode()).hexdigest()[:8]


def svc_is_scratch(svc: str) -> bool:
    """The only items the self-test may write or delete: a hashed name that is neither the pool's nor the plain login item."""
    return bool(D.POOL_ITEM_RE.fullmatch(svc)) and svc != D.item_service() and svc != PLAIN_ITEM


def kc_put(user: str, svc: str, token: str) -> bool:
    if not (svc_is_scratch(svc) and D.valid_user(user)):
        return False
    blob = {"claudeAiOauth": {"accessToken": token, "expiresAt": D.EXPIRES_AT_MS, "scopes": ["user:inference"], "subscriptionType": None}}
    cmd = f'add-generic-password -U -a "{user}" -s "{svc}" -X {json.dumps(blob).encode().hex()}\n'   # the credential rides STDIN, not argv
    try:
        r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def kc_get(user: str, svc: str) -> Tuple[str, Optional[str]]:
    """('ok', credential) | ('missing', None) | ('unknown', None) for a SCRATCH item."""
    if not (svc_is_scratch(svc) and D.valid_user(user)):
        return "unknown", None
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", user, "-s", svc, "-w"], capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return "unknown", None
    if r.returncode == 44:
        return "missing", None
    if r.returncode != 0:
        return "unknown", None
    try:
        tok = json.loads(r.stdout.strip())["claudeAiOauth"]["accessToken"]
    except (ValueError, KeyError, TypeError):
        return "unknown", None
    return ("ok", tok) if isinstance(tok, str) else ("unknown", None)


def kc_del(user: str, svc: str) -> bool:
    """True = it is gone (deleted, or never there)."""
    if not (svc_is_scratch(svc) and D.valid_user(user)):
        return False
    try:
        r = subprocess.run(["security", "delete-generic-password", "-a", user, "-s", svc], capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode in (0, 44)


def claude_timeout_s() -> float:
    try:
        return max(1.0, min(float(os.environ.get("CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S", "40")), 120.0))
    except ValueError:
        return 40.0


def logged_in(binary: str, env: dict, cwd: str) -> Tuple[str, str]:
    """('yes'|'no'|'unknown', detail): `claude auth status --json` reads the credential store and nothing else (measured: ~3 s, no inference)."""
    try:
        r = subprocess.run([binary, "auth", "status", "--json"], env=env, cwd=cwd, capture_output=True, text=True, timeout=claude_timeout_s(), check=False)
    except subprocess.TimeoutExpired:
        return "unknown", "claude auth status timed out"
    except OSError as e:
        return "unknown", f"claude could not run ({type(e).__name__})"
    try:
        v = json.loads(r.stdout)["loggedIn"]
    except (ValueError, KeyError, TypeError):
        return "unknown", f"claude auth status gave no loggedIn (rc={r.returncode})"
    return ("yes", "loggedIn=true") if v is True else ("no", "loggedIn=false") if v is False else ("unknown", "loggedIn is not a boolean")


def selftest_once(binary: str, user: str) -> Tuple[str, str]:
    """('pass'|'fail'|'inconclusive', detail). Scratch item only: the pool item, the plain login item, ~/.claude are never read or written."""
    scratch = scratch_dir()
    home = Path.home()
    if not scratch.name.startswith(SCRATCH_NAME) or scratch.is_symlink() or scratch in (Path("/"), home) or not scratch.is_absolute():
        return "inconclusive", "refusing a scratch directory that is not a dedicated one"
    secdir = str(scratch / "cred")
    svc = scratch_svc(secdir)
    if not svc_is_scratch(svc):
        return "inconclusive", "refusing: the scratch item would be the pool's or the plain login item"
    cfg = scratch / "cfg"
    token = "sk-ant-oat01-GUARDSELFTEST" + secrets.token_hex(12)
    fault = os.environ.get("CLAUDE_POOL_GUARD_FAULT", "")
    try:
        cfg.mkdir(parents=True, exist_ok=True)
        os.chmod(str(scratch), 0o700)
        env = {"HOME": os.environ.get("HOME", str(home)), "USER": user, "LOGNAME": user, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "CLAUDE_CONFIG_DIR": str(cfg), "CLAUDE_SECURESTORAGE_CONFIG_DIR": secdir}
        if not kc_del(user, svc):                         # a leftover of a killed run: start from 'absent'
            return "inconclusive", "could not clear the scratch item before the test"
        if not kc_put(user, svc, token):
            return "inconclusive", "could not write the scratch item"
        st, back = kc_get(user, svc)
        if st != "ok" or back != token:
            return "inconclusive", "the scratch item did not read back through security"
        # --- the drill: what claude would see if the credential were removed / renamed (after the harness proved it provisioned it)
        env1 = dict(env)
        if fault == "remove":
            kc_del(user, svc)
        elif fault == "rename":
            env1["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = secdir + "-renamed"
        a, da = logged_in(binary, env1, str(scratch))
        if a == "unknown":
            return "inconclusive", f"with the credential present: {da}"
        if a == "no":
            return "fail", "claude does not read the credential in the item named by CLAUDE_SECURESTORAGE_CONFIG_DIR (loggedIn=false with it present)"
        if not kc_del(user, svc) or kc_get(user, svc)[0] != "missing":
            return "inconclusive", "could not remove the scratch item for the second half of the test"
        b, db = logged_in(binary, env, str(scratch))
        if b == "unknown":
            return "inconclusive", f"with the credential removed: {db}"
        if b == "yes":
            return "fail", "claude is still logged in with the credential removed: it is not reading the item named by CLAUDE_SECURESTORAGE_CONFIG_DIR"
        return "pass", "logged in with the scratch credential present, not logged in with it removed"
    except OSError as e:
        return "inconclusive", f"scratch setup failed ({type(e).__name__})"
    finally:
        if not kc_del(user, svc):
            glog("WARN", f"the scratch item {svc} could not be removed after the self-test (it holds a fake credential; the next run clears it)")
        if scratch.name.startswith(SCRATCH_NAME) and not scratch.is_symlink() and scratch not in (Path("/"), home):
            shutil.rmtree(str(scratch), ignore_errors=True)


def run_selftest(binary: str, user: str) -> Tuple[str, str, int]:
    """A fail is repeated once after a pause before anyone acts on it: ('pass'|'fail'|'inconclusive', detail, attempts)."""
    res, detail = selftest_once(binary, user)
    if res != "fail":
        return res, detail, 1
    try:
        wait = max(0.0, min(float(os.environ.get("CLAUDE_POOL_GUARD_RETRY_WAIT_S", "5")), 60.0))
    except ValueError:
        wait = 5.0
    time.sleep(wait)
    res2, detail2 = selftest_once(binary, user)
    if res2 == "pass":
        glog("WARN", f"self-test failed once and passed on the retry (first: {detail}) - treated as pass")
        return "pass", f"passed on the retry (the first attempt: {detail})", 2
    return res2, detail2, 2


def marker_path() -> Optional[Path]:
    c = D.city()
    return c / ".gc" / D.DEGRADED_MARKER if c else None


def marker_is_ours(p: Path) -> bool:
    try:
        return json.loads(p.read_text()).get("by") == "claude-pool-guard"
    except (OSError, ValueError, AttributeError):
        return False


def write_marker(version: str, detail: str, t: float) -> bool:
    p = marker_path()
    if p is None or not p.parent.is_dir():
        glog("ERROR", "no <city>/.gc to hold the degraded marker - cannot degrade (the pool keeps following the item)")
        return False
    tmp = p.with_name(p.name + f".tmp.{os.getpid()}")
    try:
        tmp.write_text(json.dumps({"by": "claude-pool-guard", "claude": version, "since": D._iso(t), "reason": detail}) + "\n")
        os.replace(tmp, p)
    except OSError as e:
        glog("ERROR", f"could not write the degraded marker ({type(e).__name__})")
        return False
    return True


def check_selftest(gs: dict, t: float, user: str, force: bool = False) -> None:
    binary = claude_binary()
    if not binary:
        blind(gs, t, "claude-version", "claude is not on this PATH")
        return
    ver = claude_version(binary)
    if not ver:
        blind(gs, t, "claude-version", "`claude --version` gave no version")
        return
    unblind(gs, "claude-version")
    gs["claude"] = {"version": ver, "binary": binary}
    versions = _dict(gs, "versions")
    rec = versions.get(ver) if isinstance(versions.get(ver), dict) else None
    last = _num(rec.get("checked_epoch")) if rec else None
    res = rec.get("result") if rec else None
    due = (force or rec is None or last is None
           or (res == "fail" and t - last >= SELFTEST_RETRY_S)
           or (res == "inconclusive" and t - last >= INCONCLUSIVE_RETRY_S)
           or res not in ("pass", "fail", "inconclusive"))
    if due:
        result, detail, attempts = run_selftest(binary, user)
        now_rec = {"result": result, "detail": detail, "attempts": attempts, "checked_epoch": t, "checked_at": D._iso(t),
                   "first_checked_at": (rec or {}).get("first_checked_at") or D._iso(t)}
        if result == "inconclusive":
            now_rec["inconclusive_since"] = (rec or {}).get("inconclusive_since") if res == "inconclusive" else t
        versions[ver] = now_rec
        rec, res = now_rec, result
        glog("INFO" if result == "pass" else "WARN", f"SELFTEST claude={ver} result={result} attempts={attempts} detail={detail}")
    apply_result(gs, t, ver, res or "", (rec or {}).get("detail", ""))


def apply_result(gs: dict, t: float, ver: str, res: str, detail: str) -> None:
    m = marker_path()
    present = bool(m and m.exists())
    deg = gs.get("degraded") if isinstance(gs.get("degraded"), dict) else None
    if res == "fail":
        if not present and not write_marker(ver, detail, t):
            return
        if not deg or deg.get("version") != ver:
            deg = {"since": t, "version": ver, "alerted_at": None}
            gs["degraded"] = deg
            glog("WARN", f"DEGRADED: claude {ver} does not read the pool item ({detail}) - marker written, new pool launches use the ambient login")
        last = _num(deg.get("alerted_at"))
        if last is None or t - last >= REMIND_S:
            msg = (f"O teste do claude {ver} falhou: {detail}. Agentes novos usam o login atual e nenhuma sessão foi interrompida. "
                   f"A troca automática religa sozinha quando o teste voltar a passar (refeito a cada 30 min e a cada versão nova).")
            if send_alert("Pool Claude: troca automática DESLIGADA", msg, 4, True):
                deg["alerted_at"] = t
    elif res == "pass":
        if present and m is not None and marker_is_ours(m):
            try:
                m.unlink()
                glog("INFO", f"claude {ver} passes the self-test again - degraded marker removed, auto-switch is back ON")
            except OSError as e:
                glog("ERROR", f"could not remove the degraded marker ({type(e).__name__}) - auto-switch stays OFF")
                return
        elif present:
            glog("WARN", f"the degraded marker {m} was not written by this guard - left alone")
        if deg:
            if send_alert("Pool Claude: troca automática religada",
                          f"O teste do claude {ver} passou de novo: agentes novos voltam a seguir a conta do pool.", 2, False):
                gs["degraded"] = None
    elif res == "inconclusive":
        rec = _dict(gs, "versions").get(ver) or {}
        blind(gs, t, f"self-test of claude {ver}", detail, since=_num(rec.get("inconclusive_since")) or t)
    if res in ("pass", "fail"):
        unblind(gs, f"self-test of claude {ver}")


# ── 3. the daemon's liveness ───────────────────────────────────────────────────────────────────────
def check_daemon_alive(gs: dict, t: float, user: str) -> None:
    c = D.city()
    hb_path = c / ".gc" / D.HEARTBEAT_FILE if c else None
    last = None
    try:
        last = _num(json.loads(hb_path.read_text()).get("epoch")) if hb_path else None
    except (OSError, ValueError, AttributeError):
        last = None
    dstat, _ = read_decision()
    istat, _tok = D.read_item_token(user)
    if dstat == "absent" and istat == "missing" and last is None:
        gs["daemon"] = None      # never activated: nothing to be dead
        return
    ref = last
    if ref is None:              # activated (a decision or an item exists) but no clean run on record yet: count from when the guard first saw that
        d = _dict(gs, "daemon")
        d.setdefault("first_seen", t)
        ref = _num(d.get("first_seen")) or t
    d = _dict(gs, "daemon")
    if t - ref < HEARTBEAT_STALE_S:
        if d.get("stale_since") is not None:
            glog("INFO", "the daemon completes runs again")
        d["stale_since"] = None
        d["alerted_at"] = None
        return
    if d.get("stale_since") is None:
        d["stale_since"] = t
        glog("WARN", f"the daemon has not completed a clean run for {int((t - ref) // 60)} min (last: {D._iso(last) if last else 'never'}); see claude-pool-account.log")
    a = _num(d.get("alerted_at"))
    if a is None or t - a >= REMIND_S:
        if send_alert("Pool Claude: o daemon de troca não está fechando rodadas",
                      f"Nenhuma rodada limpa (sem erro) do daemon há {int((t - ref) // 60)} min (última: {D._iso(last) if last else 'nunca'}). "
                      f"O motivo está em claude-pool-account.log. O pool não troca de conta sozinho enquanto isso.", 4, True):
            d["alerted_at"] = t


# ── one pass ───────────────────────────────────────────────────────────────────────────────────────
def run_once(force_selftest: bool = False) -> int:
    off = D.operator_off()
    if off:
        glog("INFO", f"disabled by {off} - nothing done")
        return 0
    c = D.city()
    lp = c / ".gc" / "claude-pool-guard.lock" if c and (c / ".gc").is_dir() else None
    if lp is None:
        glog("ERROR", "no usable GC_CITY_PATH/.gc - cannot take the single-instance lock, refusing to run unlocked")
        return 1
    try:
        lock_fd = open(lp, "w")
    except OSError as e:
        glog("ERROR", f"cannot open the lock file {lp} ({type(e).__name__}) - refusing to run unlocked")
        return 1
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            glog("INFO", "another run holds the lock - exiting")
            return 0
        glog("ERROR", f"flock failed (errno={e.errno}) - refusing to run unlocked")
        return 1
    user = D.login_name()
    if not D.valid_user(user):
        glog("ERROR", "the login name is empty or not a plain name - refusing to build a Keychain command from it")
        return 1
    gs = load_gstate()
    if gs is None:
        return 1
    t = D.now()
    steps = [("self-test", lambda: check_selftest(gs, t, user, force_selftest))]
    if not force_selftest:
        steps += [("divergence", lambda: check_divergence(gs, t, user)), ("liveness", lambda: check_daemon_alive(gs, t, user))]
    rc = 0
    for name, fn in steps:
        try:
            # While degraded the daemon is switched off by design (its item may legitimately stop following the decision) and the alert
            # that says so already went out: the divergence and liveness checks have nothing to add. Asked per step, AFTER the self-test
            # (which is what writes and lifts the marker). The episodes are dropped, so that when auto-switch comes back an old one does
            # not alert at once: whatever is still wrong then is a new episode with its own 2 minutes.
            if name != "self-test" and D.degraded_marker():
                gs["divergence"] = None
                gs["daemon"] = None
                continue
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


# ── status ─────────────────────────────────────────────────────────────────────────────────────────
def status(as_json: bool) -> int:
    gs = load_gstate() or {}
    binary = claude_binary()
    out = {"installed_claude": claude_version(binary) if binary else None, "versions": gs.get("versions", {}),
           "degraded": bool(D.degraded_marker()), "divergence": gs.get("divergence"), "blind": gs.get("blind", {}),
           "daemon": gs.get("daemon"), "last_run": gs.get("updated")}
    cur = out["versions"].get(out["installed_claude"]) if isinstance(out["versions"], dict) else None
    out["installed_result"] = cur.get("result") if isinstance(cur, dict) else "not tested yet"
    if as_json:
        print(json.dumps(out, indent=1, sort_keys=True))
        return 0
    print(f"installed claude : {out['installed_claude']}  -> per-version self-test: {out['installed_result']}")
    print(f"auto-switch      : {'OFF (degraded marker present)' if out['degraded'] else 'on'}")
    for v, r in sorted((out["versions"] or {}).items()):
        if isinstance(r, dict):
            print(f"  claude {v:<12} {str(r.get('result')).upper():<12} {r.get('checked_at', '?')}  {r.get('detail', '')}")
    print(f"divergence       : {'OPEN since ' + D._iso(gs['divergence']['since']) if isinstance(gs.get('divergence'), dict) else 'none'}")
    print(f"guard last run   : {out['last_run']}")
    return 0


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
    if cmd in ("run-once", "selftest"):
        try:
            return run_once(force_selftest=(cmd == "selftest"))
        except Exception as e:  # noqa: BLE001 - last resort: the TYPE only
            glog("ERROR", f"unhandled {type(e).__name__} in {cmd}")
            return 1
    if cmd == "status":
        return status("--json" in argv[2:])
    print("usage: claude-pool-guard.py run-once | status [--json] | selftest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
