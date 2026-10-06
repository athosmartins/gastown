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
LIVENESS_GAP_S = 300             # two looks at the daemon further apart than this: the guard was not looking in between (asleep, unloaded, off, stood down)
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
                 "fingerprint", "login_name", "valid_user", "city", "now", "_iso", "POOL_ITEM_RE", "EXPIRES_AT_MS", "state_path", "CLOCK_SKEW_S"):
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
    guard holds) is in it.
    rc 11 means notify dropped it because a push with the same TITLE went out in the last 30 min (whatever the body says): it is counted
    as delivered here, so two different conditions must never share a title - what makes a condition different goes IN the title."""
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


def check_selftest(gs: dict, t: float, user: str, force: bool = False) -> dict:
    """What was done, for `selftest` to say: {"ran": False, "why"} or {"ran": True, "ver", "res", "detail", "effect"} (effect: see apply_result)."""
    binary = claude_binary()
    if not binary:
        blind(gs, t, "claude-version", "claude is not on this PATH")
        return {"ran": False, "why": "claude is not on this PATH"}
    ver = claude_version(binary)
    if not ver:
        blind(gs, t, "claude-version", "`claude --version` gave no version")
        return {"ran": False, "why": "`claude --version` gave no version"}
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
    detail = (rec or {}).get("detail", "")
    return {"ran": True, "ver": ver, "res": res or "", "detail": detail, "effect": apply_result(gs, t, ver, res or "", detail)}


def apply_result(gs: dict, t: float, ver: str, res: str, detail: str) -> str:
    """Act on the recorded result. Returns what became of auto-switch, for `selftest` to say: 'on' (stays on) | 'lifted' (the marker was removed now) |
    'off' (the marker was written now) | 'still-off' (the marker was already there) | 'unwritten' (the test failed and the marker CANNOT be written:
    auto-switch is still ON) | 'foreign' (the test passed but a marker this guard did not write keeps it OFF) | 'lift-failed' | 'unchanged' (inconclusive)."""
    m = marker_path()
    present = bool(m and m.exists())
    deg = gs.get("degraded") if isinstance(gs.get("degraded"), dict) else None
    if res in ("pass", "fail"):
        unblind(gs, f"self-test of claude {ver}")
    if res == "fail":
        if not present and not write_marker(ver, detail, t):
            # The worst state: the test says the pool is broken and the guard cannot switch it off. Said out loud (its own title: notify drops a
            # repeat of one within 30 min), not recorded as a degradation that did not happen, and tried again on every tick.
            mf = gs.get("marker_failed") if isinstance(gs.get("marker_failed"), dict) else None
            if not mf or mf.get("version") != ver:
                mf = {"since": t, "version": ver, "alerted_at": None}
                gs["marker_failed"] = mf
            last = _num(mf.get("alerted_at"))
            if last is None or t - last >= REMIND_S:
                where = str(m.parent) if m else "<city>/.gc (GC_CITY_PATH is not set)"
                msg = (f"O teste do claude {ver} falhou ({detail}), mas o guarda NÃO conseguiu gravar o marcador em {where}: "
                       f"a troca automática continua ligada e agentes novos seguem apontando para o item do pool. Tenta de novo a cada minuto; "
                       f"o motivo está em claude-pool-guard.log.")
                if send_alert(f"Pool Claude: troca automática NÃO foi desligada (claude {ver})", msg, 4, True):
                    mf["alerted_at"] = t
            return "unwritten"
        gs.pop("marker_failed", None)
        if not deg or deg.get("version") != ver:
            deg = {"since": t, "version": ver, "alerted_at": None}
            gs["degraded"] = deg
            glog("WARN", f"DEGRADED: claude {ver} does not read the pool item ({detail}) - marker written, new pool launches use the ambient login")
        last = _num(deg.get("alerted_at"))
        if last is None or t - last >= REMIND_S:
            msg = (f"O teste do claude {ver} falhou: {detail}. Agentes novos usam o login atual e nenhuma sessão foi interrompida. "
                   f"A troca automática religa sozinha quando o teste voltar a passar (refeito a cada 30 min e a cada versão nova).")
            if send_alert(f"Pool Claude: troca automática DESLIGADA (claude {ver})", msg, 4, True):
                deg["alerted_at"] = t
        return "still-off" if present else "off"
    if res == "pass":
        gs.pop("marker_failed", None)
        effect = "on"
        if present and m is not None and marker_is_ours(m):
            try:
                m.unlink()
                glog("INFO", f"claude {ver} passes the self-test again - degraded marker removed, auto-switch is back ON")
                effect = "lifted"
            except OSError as e:
                glog("ERROR", f"could not remove the degraded marker ({type(e).__name__}) - auto-switch stays OFF")
                return "lift-failed"
        elif present:
            # Someone else's marker keeps the mechanism off: it is not the guard's to lift and it is not "back on" - so nothing is announced
            # and the record of the degradation stays until the marker is really gone.
            glog("WARN", f"the degraded marker {m} was not written by this guard - left alone (auto-switch stays OFF)")
            return "foreign"
        if deg:
            if send_alert(f"Pool Claude: troca automática religada (claude {ver})",
                          f"O teste do claude {ver} passou de novo: agentes novos voltam a seguir a conta do pool.", 2, False):
                gs["degraded"] = None
        return effect
    if res == "inconclusive":
        rec = _dict(gs, "versions").get(ver) or {}
        blind(gs, t, f"self-test of claude {ver}", detail, since=_num(rec.get("inconclusive_since")) or t)
    return "unchanged"


# ── 3. the daemon's liveness ───────────────────────────────────────────────────────────────────────
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
    absence: a reboot, a sleep, launchd unloaded) or while the daemon was stood down on purpose (the marker, the operator's switches: the real
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
SELFTEST_EFFECT = {
    "on": "auto-switch is on",
    "lifted": "auto-switch is now on (the degraded marker was removed)",
    "off": "auto-switch is now OFF (the degraded marker was written: new pool launches use the current login)",
    "still-off": "auto-switch stays OFF (the degraded marker was already there)",
    "unwritten": "auto-switch is NOT off: the test failed but the degraded marker could not be written (see the guard log); it is still ON",
    "foreign": "auto-switch stays OFF: a degraded marker this guard did not write is up, and it is left alone",
    "lift-failed": "auto-switch stays OFF: the degraded marker could not be removed (see the guard log)",
}


def report_selftest(out: dict) -> int:
    """`selftest` is asked by a person: it says what it did. rc 0 = pass, 3 = fail, 4 = inconclusive (1 = the test was NOT run, said by run_once)."""
    ver, res, detail, effect = out["ver"], out["res"], out["detail"], out["effect"]
    print(f"claude {ver}: {res}" + (f" ({detail})" if detail else ""))
    if res == "inconclusive":
        print("the test could not tell: nothing was changed")
        return 4
    print(SELFTEST_EFFECT.get(effect, effect))
    return 0 if res == "pass" else 3


def run_once(force_selftest: bool = False) -> int:
    """The launchd tick (quiet: it logs, rc 0 when it has nothing to do) and `selftest` (a person is asking: it prints what it did and returns
    0 pass / 3 fail / 4 inconclusive / 1 NOT run, so 'it did nothing' cannot look like 'it passed')."""
    def not_run(why: str, quiet_rc: int) -> int:
        glog("INFO" if quiet_rc == 0 else "ERROR", why)
        if force_selftest:
            print(f"claude-pool-guard selftest: the self-test was NOT run: {why}")
            return 1
        return quiet_rc
    off = D.operator_off()
    if off:
        return not_run(f"disabled by {off} - nothing done", 0)
    c = D.city()
    lp = c / ".gc" / "claude-pool-guard.lock" if c and (c / ".gc").is_dir() else None
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
    outcome: dict = {}
    steps = [("self-test", lambda: outcome.update(check_selftest(gs, t, user, force_selftest)))]
    if not force_selftest:
        steps += [("divergence", lambda: check_divergence(gs, t, user)), ("liveness", lambda: check_daemon_alive(gs, t, user))]
    rc = 0
    for name, fn in steps:
        try:
            # While degraded the daemon is stood down by design: it does not switch and (the real one) does not stamp its heartbeat, and the
            # alert that says so already went out, so the divergence and liveness checks have nothing to add. Asked per step, AFTER the
            # self-test (which is what writes and lifts the marker). What is dropped: the divergence episode (when auto-switch comes back,
            # whatever is still wrong is a NEW episode with its own debounce), the 'could not tell' records (their 30 minutes must not run
            # on through a stand-down) and the daemon's record, re-based on this tick - so the daemon's silence is judged from the moment
            # the guard looks at it again, never over the stand-down (see check_daemon_alive).
            if name != "self-test" and D.degraded_marker():
                gs["divergence"] = None
                gs["daemon"] = {"checked_at": t, "watch_since": t}
                unblind(gs, "divergence")
                unblind(gs, "daemon-heartbeat")
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
    if force_selftest:
        if not outcome:
            return not_run("the self-test step failed unexpectedly (see the guard log)", 1)
        if not outcome.get("ran"):
            return not_run(outcome.get("why") or "see the guard log", 1)
        return report_selftest(outcome) or rc
    return rc


# ── status ─────────────────────────────────────────────────────────────────────────────────────────
def peek_gstate() -> Tuple[str, dict]:
    """('absent'|'ok'|'corrupt'|'unreadable', state). Read-only: load_gstate moves a corrupt file aside, and `status` has no side effect."""
    p = gstate_path()
    try:
        raw = p.read_bytes()
    except FileNotFoundError:
        return "absent", {}
    except OSError:
        return "unreadable", {}
    try:
        d = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        return "corrupt", {}
    return ("ok", d) if isinstance(d, dict) else ("corrupt", {})


def marker_state() -> Tuple[str, str]:
    """('on'|'off'|'unknown', why). D.degraded_marker() answers 'no marker' for "there is no city to look in" too, and `status` is how one asks
    'is auto-switch OFF?': a question that cannot be answered says so instead of answering 'on'."""
    c = D.city()
    if not c:
        return "unknown", "GC_CITY_PATH is not set: there is no city to look for the marker in - run it where the agents do, or export GC_CITY_PATH"
    gc = c / ".gc"
    try:
        if not gc.is_dir():
            return "unknown", f"{gc} is not a directory - is GC_CITY_PATH right?"
        (gc / D.DEGRADED_MARKER).lstat()
    except FileNotFoundError:
        return "on", ""
    except OSError as e:
        return "unknown", f"cannot look in {gc} ({type(e).__name__})"
    return "off", ""


def status(as_json: bool) -> int:
    """Exit 0 = it could say what the state file says (including 'nothing recorded yet') and whether auto-switch is on; 1 = it could not read
    the state file, or could not look for the degraded marker."""
    sstat, gs = peek_gstate()
    binary = claude_binary()
    installed = claude_version(binary) if binary else None
    versions = gs.get("versions") if isinstance(gs.get("versions"), dict) else {}
    mstate, mwhy = marker_state()
    out = {"state_file": sstat, "installed_claude": installed, "versions": versions,
           "degraded": {"on": False, "off": True}.get(mstate),   # null = could not look
           "auto_switch": {"on": "on", "off": "OFF"}.get(mstate, f"unknown ({mwhy})"),
           "divergence": gs.get("divergence"), "blind": gs.get("blind", {}),
           "daemon": gs.get("daemon"), "last_run": gs.get("updated")}
    cur = versions.get(installed) if installed else None
    if sstat in ("corrupt", "unreadable"):
        out["installed_result"] = f"unknown (the guard's state file is {sstat})"
    elif not installed:
        out["installed_result"] = "unknown (the installed claude version could not be read)"
    else:
        out["installed_result"] = cur.get("result") if isinstance(cur, dict) and cur.get("result") else "not tested yet"
    rc = 1 if sstat in ("corrupt", "unreadable") or mstate == "unknown" else 0
    if as_json:
        print(json.dumps(out, indent=1, sort_keys=True))
        return rc
    print(f"installed claude : {installed or '?'}  -> per-version self-test: {out['installed_result']}")
    print(f"auto-switch      : {'OFF (degraded marker present)' if mstate == 'off' else out['auto_switch']}")
    for v, r in sorted(versions.items()):
        if isinstance(r, dict):
            print(f"  claude {v:<12} {str(r.get('result')).upper():<12} {r.get('checked_at', '?')}  {r.get('detail', '')}")
    dv = gs.get("divergence") if isinstance(gs.get("divergence"), dict) else None
    since = _num(dv.get("since")) if dv else None
    print(f"divergence       : {('OPEN since ' + D._iso(since)) if since is not None else ('OPEN (since unknown)' if dv else 'none')}")
    print(f"guard last run   : {out['last_run']}")
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
