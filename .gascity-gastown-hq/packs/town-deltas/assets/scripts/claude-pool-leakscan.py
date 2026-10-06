#!/usr/bin/env python3
"""claude-pool-leakscan — ga-8hcnvb.3: does any of the pool accounts' keys sit where it must not?

The pool moves between Claude accounts by writing a key into one Keychain item. The promise is that a key lives in the vault and in that
item and NOWHERE else: not in a process's argv or environment, not in a log, not in the decision file, not in an error message, not in a
notification. This tool looks for the keys in the places that would break the promise and says where it found one. It never says what it
found around it: a finding is  channel, location (a path or a pid + command name), account (e-mail + 8-hex fingerprint), form, count.

  claude-pool-leakscan.py --keys-stdin|--keys-vault [--ps] [--path P ...]        scan once
  claude-pool-leakscan.py --keys-stdin|--keys-vault --watch-ps STOPFILE [--ready-file F]   sample ps until STOPFILE exists, then report
                                                                                          (F is created once the sampler is up)
  options: --json  --interval S (watch, default 0.05)  --watch-max S (default 900)  --chunk BYTES

KEYS arrive on STDIN as JSON {"<email>": "<key>", ...} or from the accounts library (--keys-vault: the same vault the pool uses). Never in
argv, never in the environment, never in a file: the scanner of key leaks must not be one.

FORMS looked for, per key: the raw text; its hex (lower and upper case: the Keychain blob is passed to `security` as hex); its base64 and
URL-safe base64 at the three byte alignments a key can have inside a longer base64 text. And, for any text that looks like a key but is not
one of ours, the shape  sk-ant-<8+ token characters>  (reported as form=shape, unattributed, with the fingerprint of what matched).

THE CONTROL runs first, always: it plants a random fake key on every channel this scan uses (a file, one that straddles a read boundary,
a process argv, a process environment) and requires the scanner to find it in every form. A scanner that cannot see what was planted on
purpose proves nothing about the real thing, so a failed control means exit 3 - never a green result.

EXIT  0 = nothing found and the control saw what it planted.  1 = a key was found (key-shaped text that is none of ours counts too, in a
file; in the process list - the whole machine's - it is only a NOTE line).  3 = the scan is BLIND: the control failed, or a path
could not be read, or a key is too short to search for, or the keys could not all be loaded. 2 = usage.
(Exit 1 wins over 3: a hit is a hit even when something else could not be looked at.)
"""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

CHUNK = 4 << 20
SHAPE_RE = re.compile(rb"sk-ant-[A-Za-z0-9_\-]{8,}")
MIN_KEY_LEN = 20            # a shorter needle matches innocent text and proves nothing
SKIP_ENDINGS = ()           # nothing is skipped: a file that is not looked at is a blind spot, not a clean one
DEFAULT_ACCOUNTS_LIB = "/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py"

Finding = Tuple[str, str, str, str]   # (channel, location, account, form)


def fp8(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()[:8]


# ── what to look for ───────────────────────────────────────────────────────────────────────────────
def _b64_aligned(key: bytes, urlsafe: bool) -> List[Tuple[str, bytes]]:
    """The base64 of `key` as it appears inside a longer base64 text, for the 3 positions the key can start at modulo 3. The characters
    that also depend on the bytes before or after the key are dropped, so what is left occurs verbatim whenever the key does."""
    enc = base64.urlsafe_b64encode if urlsafe else base64.b64encode
    out = []
    for k, skip in ((0, 0), (1, 2), (2, 3)):
        full = ((k + len(key)) // 3) * 4
        s = enc(b"\xff" * k + key)[skip:full].rstrip(b"=")
        out.append((f"b64url:{k}" if urlsafe else f"b64:{k}", s))
    return out


def forms_of(key: bytes) -> List[Tuple[str, bytes]]:
    f = [("raw", key), ("hex", key.hex().encode()), ("HEX", key.hex().upper().encode())]
    f += _b64_aligned(key, False) + _b64_aligned(key, True)
    seen, out = set(), []
    for name, n in f:
        if n and n not in seen:
            seen.add(n)
            out.append((name, n))
    return out


class Needles:
    def __init__(self, keys: Dict[str, bytes]):
        self.items: List[Tuple[str, str, bytes]] = []      # (account label, form, needle)
        self.raw: List[Tuple[str, bytes]] = []
        for email, key in sorted(keys.items()):
            label = f"{email} (fp {fp8(key)})"
            self.raw.append((label, key))
            for form, n in forms_of(key):
                self.items.append((label, form, n))
        self.maxlen = max([len(n) for _, _, n in self.items] + [64])


# ── scanning a byte stream ─────────────────────────────────────────────────────────────────────────
def scan_buffer_stream(read, nd: Needles, chunk: int) -> Dict[Tuple[str, str], Set[int]]:
    """read(n) -> bytes ('' at the end). Returns {(account, form): {absolute start offsets}} for the known keys, and
    {("", "shape:<fp8>"): {offsets}} for key-shaped text that is not one of ours. Offsets de-duplicate what the overlap sees twice."""
    hits: Dict[Tuple[str, str], Set[int]] = {}
    raw_pos: Set[int] = set()
    shape: Dict[int, str] = {}
    carry, base = b"", 0
    while True:
        data = read(chunk)
        buf = carry + data
        for label, form, n in nd.items:
            i = buf.find(n)
            while i >= 0:
                hits.setdefault((label, form), set()).add(base + i)
                if form == "raw":
                    raw_pos.add(base + i)
                i = buf.find(n, i + 1)
        for m in SHAPE_RE.finditer(buf):
            shape.setdefault(base + m.start(), fp8(m.group(0)))
        if not data:
            break
        keep = min(len(buf), nd.maxlen - 1)
        base += len(buf) - keep
        carry = buf[len(buf) - keep:]
    for pos, fp in shape.items():
        if pos not in raw_pos:
            hits.setdefault(("", f"shape:{fp}"), set()).add(pos)
    return hits


def scan_file(path: Path, nd: Needles, chunk: int) -> Tuple[List[Tuple[str, str, int]], Optional[str]]:
    """([(account, form, count)], error or None). A file that cannot be read completely is an error, not a clean file."""
    try:
        with open(path, "rb") as f:
            hits = scan_buffer_stream(f.read, nd, chunk)
    except OSError as e:
        return [], f"{type(e).__name__}"
    return [(a, fo, len(p)) for (a, fo), p in sorted(hits.items())], None


def walk(paths: Iterable[Path]) -> Tuple[List[Path], List[Tuple[Path, str]]]:
    files, errors = [], []
    for p in paths:
        if p.is_symlink():
            errors.append((p, "is a symlink (not followed)"))
        elif p.is_file():
            files.append(p)
        elif p.is_dir():
            try:
                for root, dirs, names in os.walk(p, followlinks=False, onerror=lambda e: errors.append((Path(str(e.filename)), type(e).__name__))):
                    for n in sorted(names):
                        q = Path(root) / n
                        if q.is_symlink():
                            continue
                        files.append(q)
            except OSError as e:
                errors.append((p, type(e).__name__))
        else:
            errors.append((p, "does not exist"))
    return files, errors


def scan_paths(paths: List[Path], nd: Needles, chunk: int) -> Tuple[List[Finding], Dict[Finding, int], List[Tuple[Path, str]]]:
    files, errors = walk(paths)
    counts: Dict[Finding, int] = {}
    for f in files:
        res, err = scan_file(f, nd, chunk)
        if err:
            errors.append((f, err))
        for acct, form, n in res:
            k = ("file", str(f), acct or "<not one of the known keys>", form)
            counts[k] = counts.get(k, 0) + n
    return list(counts), counts, errors


# ── ps: argv and environment of every process of this user ─────────────────────────────────────────
def ps_snapshot() -> Optional[List[Tuple[str, int, str, bytes]]]:
    """[(channel, pid, command name, line)] from `ps -axww` (argv) and `ps -Eaxww` (argv + environment); None = ps could not run."""
    out: List[Tuple[str, int, str, bytes]] = []
    for channel, flags in (("ps-argv", "-axww"), ("ps-env", "-Eaxww")):   # NB: `-axeww` does NOT show the environment on macOS; `-E` does
        try:
            r = subprocess.run(["ps", flags, "-o", "pid=,command="], capture_output=True, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        if r.returncode != 0:
            return None
        for line in r.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit() or int(parts[0]) == os.getpid():
                continue
            argv0 = parts[1].split(b" ", 1)[0]
            out.append((channel, int(parts[0]), os.path.basename(argv0.decode("utf-8", "replace")) or "?", parts[1]))
    return out


def scan_bytes(data: bytes, nd: Needles) -> Dict[Tuple[str, str], Set[int]]:
    box = [data]
    return scan_buffer_stream(lambda n: box.pop() if box else b"", nd, max(len(data), 1))


ENV_NAME_BEFORE = re.compile(rb"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=$")


def var_names(line: bytes, positions: Iterable[int]) -> str:
    """',NAME' for each environment variable whose value starts at one of `positions` (the NAME only: never anything of the value)."""
    names = sorted({m.group(1).decode() for p in positions for m in [ENV_NAME_BEFORE.search(line[max(0, p - 80):p])] if m})
    return (" var=" + ",".join(names)) if names else ""


def scan_ps_snapshot(snap: List[Tuple[str, int, str, bytes]], nd: Needles) -> Dict[Finding, int]:
    counts: Dict[Finding, int] = {}
    for channel, pid, comm, line in snap:
        for (acct, form), pos in scan_bytes(line, nd).items():
            name = "<redacted>" if (SHAPE_RE.search(comm.encode()) or any(n in comm.encode() for _, _, n in nd.items)) else comm
            via = var_names(line, pos) if channel == "ps-env" else ""
            k = (channel, f"pid {pid} {name}{via}", acct or "<not one of the known keys>", form)
            counts[k] = counts.get(k, 0) + len(pos)
    return counts


def watch_ps(stopfile: Path, nd: Needles, interval: float, max_s: float, ready: Optional[Path] = None) -> Tuple[Dict[Finding, int], int]:
    """Samples ps until `stopfile` exists (then once more) and returns (findings, samples). Only hits are kept: the samples are not.
    `ready` is created after the first sample: whoever starts the scenario waits for it, so the sampling window really contains it."""
    counts: Dict[Finding, int] = {}
    samples = 0
    deadline = time.time() + max_s
    last = False
    while True:
        snap = ps_snapshot()
        if snap is not None:
            samples += 1
            if ready is not None and samples == 1:
                try:
                    ready.write_text("ready\n")
                except OSError:
                    pass
            for k, v in scan_ps_snapshot(snap, nd).items():
                counts[k] = counts.get(k, 0) + v
        if last or time.time() > deadline:
            break
        if stopfile.exists():
            last = True
            continue
        time.sleep(interval)
    return counts, samples


# ── the control ────────────────────────────────────────────────────────────────────────────────────
def _spawn(args: List[str], env: Optional[Dict[str, str]] = None) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(25)"] + args, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _wait_for(pred, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.1)
    return pred()


def control(use_files: bool, use_ps: bool, chunk: int) -> List[str]:
    """Plants a fake key on each channel the scan will use and returns what the scanner FAILED to find ([] = it sees what is planted)."""
    failures: List[str] = []
    fake = ("sk-ant-oat01-CONTROL" + secrets.token_hex(14)).encode()
    stranger = ("sk-ant-oat01-STRANGER" + secrets.token_hex(14)).encode()      # shaped like a key, not in the needle set
    nd = Needles({"control@scanner.invalid": fake})
    want_forms = {f for f, _ in forms_of(fake)}
    if use_files:
        with tempfile.TemporaryDirectory(prefix="leakscan-control.") as d:
            planted = Path(d) / "planted.log"
            lines = [b"raw   " + fake, b"hex   " + fake.hex().encode(), b"HEX   " + fake.hex().upper().encode(), b"shape " + stranger]
            for k in (0, 1, 2):
                for urlsafe in (False, True):
                    enc = base64.urlsafe_b64encode if urlsafe else base64.b64encode
                    lines.append(b"b64%d  " % k + enc(b"A" * (3 * 5 + k) + fake + b"Z" * 7))   # the key inside longer base64, at offset k mod 3
            planted.write_bytes(b"\n".join(lines) + b"\n")
            res, err = scan_file(planted, nd, chunk)
            got = {fo for _, fo, _ in res}
            missing = sorted(want_forms - got)
            if err or missing:
                failures.append(f"file: not found in the planted file: {','.join(missing) or err}")
            if not any(fo.startswith("shape:") for fo in got):
                failures.append("file: a key-shaped stranger was not found")
            # a key that straddles two reads (and a third one in the middle of a longer file) must still be seen, once
            straddle = Path(d) / "straddle.log"
            pad = max(chunk, 64)
            straddle.write_bytes(b"x" * (pad - 10) + fake + b"y" * (2 * pad) + fake + b"z" * 5)
            res, err = scan_file(straddle, nd, chunk)
            n_raw = sum(c for _, fo, c in res if fo == "raw")
            if err or n_raw != 2:
                failures.append(f"file: a key straddling a read boundary was counted {n_raw} times, want 2")
    if use_ps:
        env = dict(os.environ)
        env["LEAKSCAN_CONTROL_ENV"] = fake.decode()
        pa = _spawn(["LEAKSCAN_CONTROL_ARGV=" + fake.decode()], env={k: v for k, v in os.environ.items() if not k.startswith("LEAKSCAN_")})
        pe = _spawn([], env=env)
        try:
            def seen(channel: str, loc_pid: int) -> bool:
                snap = ps_snapshot()
                if snap is None:
                    return False
                return any(k[0] == channel and k[1].startswith(f"pid {loc_pid} ") for k in scan_ps_snapshot(snap, nd))
            if not _wait_for(lambda: seen("ps-argv", pa.pid), 8):
                failures.append("ps-argv: a key in a process's argv was not found")
            if not _wait_for(lambda: seen("ps-env", pe.pid), 8):
                failures.append("ps-env: a key in a process's environment was not found")
        finally:
            for p in (pa, pe):
                p.kill()
                p.wait()
    return failures


# ── keys ───────────────────────────────────────────────────────────────────────────────────────────
def load_keys(source: str) -> Tuple[Dict[str, bytes], List[str]]:
    """({email: key bytes}, problems). Problems make the scan blind: a key that is not searched for is a leak that is not seen."""
    problems: List[str] = []
    keys: Dict[str, bytes] = {}
    if source == "stdin":
        try:
            d = json.loads(sys.stdin.read())
        except ValueError:
            return {}, ["stdin is not JSON"]
        if not isinstance(d, dict) or not d:
            return {}, ["stdin must be a non-empty JSON object {email: key}"]
        for e, k in d.items():
            if isinstance(k, str) and k:
                keys[str(e)] = k.encode()
            else:
                problems.append(f"no key given for {e}")
    else:
        p = Path(os.environ.get("CLAUDE_POOL_ACCOUNTS_LIB") or DEFAULT_ACCOUNTS_LIB)
        try:
            spec = importlib.util.spec_from_file_location("claude_account_pool_ext", str(p))
            lib = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(lib)
            emails = [e for e in lib.ordem_das_contas() if isinstance(e, str) and e]
        except Exception as e:  # noqa: BLE001
            return {}, [f"the accounts library could not be used ({type(e).__name__})"]
        if not emails:
            return {}, ["the accounts library lists no account"]
        for e in emails:
            try:
                tok = lib.token_da_conta(e)
            except Exception:  # noqa: BLE001
                tok = None
            if tok:
                keys[e] = tok.encode()
            else:
                problems.append(f"the key of {e} could not be read from the vault (not the same as 'it has none')")
    for e, k in list(keys.items()):
        if len(k) < MIN_KEY_LEN:
            problems.append(f"the key of {e} is shorter than {MIN_KEY_LEN} characters: not searchable without false hits")
            del keys[e]
    if not keys:
        problems.append("no searchable key")
    return keys, problems


# ── main ───────────────────────────────────────────────────────────────────────────────────────────
def report(counts: Dict[Finding, int], as_json: bool) -> None:
    rows = [{"channel": c, "location": loc, "account": a, "form": fo, "count": n} for (c, loc, a, fo), n in sorted(counts.items())]
    if as_json:
        return
    for r in rows:
        print(f"LEAK channel={r['channel']} location={r['location']} account={r['account']} form={r['form']} count={r['count']}")


def main(argv: List[str]) -> int:
    args = argv[1:]
    src = None
    paths: List[Path] = []
    use_ps = False
    watch: Optional[Path] = None
    ready: Optional[Path] = None
    as_json = False
    interval, watch_max, chunk = 0.05, 900.0, CHUNK
    i = 0
    try:
        while i < len(args):
            a = args[i]
            if a == "--keys-stdin":
                src = "stdin"
            elif a == "--keys-vault":
                src = "vault"
            elif a == "--ps":
                use_ps = True
            elif a == "--path":
                i += 1
                paths.append(Path(args[i]))
            elif a == "--watch-ps":
                i += 1
                watch = Path(args[i])
            elif a == "--ready-file":
                i += 1
                ready = Path(args[i])
            elif a == "--json":
                as_json = True
            elif a == "--interval":
                i += 1
                interval = float(args[i])
            elif a == "--watch-max":
                i += 1
                watch_max = float(args[i])
            elif a == "--chunk":
                i += 1
                chunk = int(args[i])
            else:
                raise ValueError(a)
            i += 1
    except (ValueError, IndexError):
        src = None
    if src is None or (watch is None and not paths and not use_ps) or chunk < 64:
        print(__doc__.split("\n\n")[0] + "\n\nusage: claude-pool-leakscan.py (--keys-stdin|--keys-vault) [--ps] [--path P ...] [--watch-ps STOPFILE [--ready-file F]] [--json]",
              file=sys.stderr)
        return 2
    keys, problems = load_keys(src)
    blind: List[str] = list(problems)
    if not keys:
        for p in blind:
            print(f"BLIND {p}")
        return 3
    nd = Needles(keys)
    fails = control(use_files=bool(paths), use_ps=use_ps or watch is not None, chunk=min(chunk, 4096))
    blind += [f"control: {f}" for f in fails]
    counts: Dict[Finding, int] = {}
    samples = 0
    if not fails:
        if watch is not None:
            c, samples = watch_ps(watch, nd, interval, watch_max, ready)
            counts.update(c)
            if samples == 0:
                blind.append("ps could not be sampled")
        else:
            if use_ps:
                snap = ps_snapshot()
                if snap is None:
                    blind.append("ps could not run")
                else:
                    counts.update(scan_ps_snapshot(snap, nd))
            if paths:
                _, c, errors = scan_paths(paths, nd, chunk)
                counts.update(c)
                blind += [f"{p}: {why}" for p, why in errors]
    # The process list is the whole machine's, not the pool's: key-shaped text there that is none of OUR keys (an API key of some other
    # service in its environment, say) is worth a line, not a failed scan. In a FILE the product wrote it is a finding.
    notes = {k: v for k, v in counts.items() if k[0].startswith("ps-") and k[3].startswith("shape:")}
    counts = {k: v for k, v in counts.items() if k not in notes}
    rows = [{"channel": c, "location": loc, "account": a, "form": fo, "count": n} for (c, loc, a, fo), n in sorted(counts.items())]
    if as_json:
        print(json.dumps({"keys": len(keys), "findings": rows, "blind": blind, "samples": samples,
                          "notes": [{"channel": c, "location": loc, "form": fo, "count": n} for (c, loc, _a, fo), n in sorted(notes.items())],
                          "control": "failed" if fails else "ok"}, indent=1, sort_keys=True))
    else:
        report(counts, False)
        for (c, loc, _a, fo), n in sorted(notes.items()):
            print(f"NOTE channel={c} location={loc} form={fo} count={n} (key-shaped text that is none of the pool's keys, in a process list that covers the whole machine: not a failure)")
        for b in blind:
            print(f"BLIND {b}")
        print(f"SUMMARY keys={len(keys)} findings={sum(counts.values())} locations={len(counts)} blind={len(blind)} notes={len(notes)} "
              f"control={'FAILED' if fails else 'ok'}" + (f" samples={samples}" if watch is not None else ""))
    if counts:
        return 1
    return 3 if blind else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
