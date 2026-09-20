"""gc_ledger.py — shared append-only JSONL ledger helper, Python interface (imp04).

Importable by imp02, imp24, imp25, or any Python daemon.

ATOMICITY: uses O_WRONLY | O_APPEND | O_CREAT. On POSIX, a single write() to an
O_APPEND file descriptor is atomic for writes ≤ PIPE_BUF (64KiB on macOS/Linux).
JSON ledger lines are always well under that limit. No lock needed.

DOLT-INDEPENDENT: never calls bd, gc, dolt, or any network service.
FAIL-OPEN: all errors are logged to stderr and raised as LedgerError; callers
should catch or use the fail_open=True parameter to suppress exceptions.

Public API (stable names — imp02/imp24/imp25 import by these):
  gc_ledger_append(ledger_name, data, *, fail_open=False) -> None
    ledger_name: str, e.g. "flow-ledger"  →  flow-ledger.jsonl
    data: dict or str (pre-serialized JSON)
    fail_open: if True, swallows LedgerError instead of raising

  LEDGER_DIR: str — the canonical ledger directory (import to get the path)
  LIVE_LEDGER_DIR: str — the production ledger directory (what LEDGER_DIR is
    unless GC_LEDGER_DIR overrides it); the selftest guard below protects it
  LIVE_FLOW_AUTHORITY_FILE: str — the production flow-authority marker path
  ledger_path(ledger_name) -> str — full path to the .jsonl file
  selftest_signal() -> str | None — why this process is positively a test run
  selftest_blocks_live_write(path, live_path) -> str | None — same predicate for
    other live-STATE writers to share
  flow_authority_write_blocked(path) -> str | None — that predicate bound to the
    live flow-authority.json; the throughput-stall-watchdog and the
    approved-state-reconciler call it before they write their marker

SELFTEST GUARD (ga-9d7it9): a selftest that reaches gc_ledger_append with the
default LEDGER_DIR used to append fixture rows to the PRODUCTION ledgers. Measured
2026-09-20 on human-touch.jsonl, per source_daemon, counting a row as a fixture
when its bead_id is a digits-only hq-NNN/wa-NNN (no real bead has one) or it
sits in a same-second burst of >=20 rows from the same daemon: 5294 of the
approved-state-reconciler's 6095 rows (87%; 67% by the id rule alone) and 1150 of
the throughput-stall-watchdog's 2558 (45%). Stubbing one selftest at a time never
closes that class (every new selftest defaults to "write to production"), so the
shared writer enforces it: when the process is POSITIVELY a test run
(PYTEST_CURRENT_TEST, an exact --selftest / --self-test argv flag, GC_SELFTEST set
truthy, or a `python -m unittest` runner) AND the target is the live dir, writes
go to a per-process scratch dir
instead and ledger_path() follows them. It only ever acts on a positive signal:
"can't tell" is production behaviour, and under a positive signal it never falls
back to the live dir (an unusable scratch raises LedgerError, which fail_open
callers already swallow). An explicit GC_LEDGER_DIR pointing anywhere else is
honoured exactly as before.

SCOPE LIMIT — the signals are per-PROCESS: argv and pytest's env do not cross a
subprocess boundary, and a `python3 -c` harness has argv ['-c'], so it carries no
signal at all. A selftest that runs a writer in a CHILD process (including a shell
script calling `python3 gc_ledger.py <name> <json>`) or through `python3 -c` must
export GC_SELFTEST=1 (or point GC_LEDGER_DIR at a scratch dir) for that process —
see production-stall-watchdog.selftest.sh. Direct-file writers (a bash daemon's own
`>> "$LOG"`) are not gc_ledger and are not covered at all.

Usage:
  from gc_ledger import gc_ledger_append, LEDGER_DIR
  gc_ledger_append("flow-ledger", {"ts": "2026-06-23T10:00:00Z", "event": "snapshot"})
"""

from __future__ import annotations

import atexit
import json
import os
import shutil
import sys
import tempfile
import threading
from pathlib import Path
from typing import Optional, Union

# ── config ────────────────────────────────────────────────────────────────────
# LIVE_LEDGER_DIR is its own constant (not only the env default) so the selftest
# guard can tell "this write would hit production" apart from "a selftest already
# pointed GC_LEDGER_DIR at its own scratch dir".
LIVE_LEDGER_DIR: str = "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"
LEDGER_DIR: str = os.environ.get("GC_LEDGER_DIR", LIVE_LEDGER_DIR)
# The production flow-authority marker: written by the throughput-stall-watchdog and
# the approved-state-reconciler, READ by pipeline-throughput-heartbeat, the
# production-stall-watchdog and funnel-flow-healer to decide whether to DEFER their
# own Mayor mail. Same reason as above for being a constant of its own: a selftest
# that already points the daemon's *_FLOW_AUTHORITY_FILE env at a scratch path is
# hermetic and must be honoured, only the real path is protected.
LIVE_FLOW_AUTHORITY_FILE: str = "/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/flow-authority.json"


class LedgerError(RuntimeError):
    """Raised when a ledger write fails (unless fail_open=True)."""


# ── selftest guard (ga-9d7it9) ────────────────────────────────────────────────
# Exact flags only: a prod daemon whose argv merely CONTAINS the word (a bead
# title, a log path) must never be diverted into scratch.
_SELFTEST_ARGV_FLAGS = ("--selftest", "--self-test")
# An exported-but-falsy GC_SELFTEST must read as OFF — the classic way a guard
# turns itself on by accident and silently eats production rows.
_FALSY_ENV = ("", "0", "false", "no", "off")

_scratch_dir: Optional[str] = None
_announced: bool = False
_scratch_lock = threading.Lock()


def selftest_signal() -> Optional[str]:
    """Why this process is POSITIVELY a test/selftest run, or None.

    None means "not known to be a test" — which includes "couldn't tell": the
    guard is opt-in on a positive signal, so any doubt keeps production behaviour.
    """
    try:
        if os.environ.get("PYTEST_CURRENT_TEST"):
            return "PYTEST_CURRENT_TEST"
        flag = os.environ.get("GC_SELFTEST", "").strip().lower()
        if flag not in _FALSY_ENV:
            return f"GC_SELFTEST={flag}"
        if any(a in _SELFTEST_ARGV_FLAGS for a in sys.argv[1:]):
            return "argv --selftest"
        # `python -m unittest` carries no flag and no pytest env — the runner IS __main__
        # (a plain script run has __main__.__spec__ == None). Compared on the TOP package
        # name, so `unittesting.x` / `pkg.unittest_helpers` are not the runner.
        main_spec = getattr(sys.modules.get("__main__"), "__spec__", None)
        if (getattr(main_spec, "name", "") or "").partition(".")[0] == "unittest":
            return "python -m unittest"
    except Exception:  # embedded interpreter without sys.argv, etc.
        return None
    return None


def _same_path(a: str, b: str) -> bool:
    """Resolved-path equality, so a symlink to the live dir is still the live dir.

    Only ever consulted under a positive test signal, where the inert answer to
    "can't tell whether this is live" is True (divert), never False (write).
    """
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except Exception:
        return True


def selftest_blocks_live_write(path: str, live_path: str) -> Optional[str]:
    """Reason string when `path` IS the live artifact `live_path` AND this process
    is positively a test run — the caller must then skip/redirect the write.
    None means the write is allowed. Shared by live-STATE writers (flow-authority)."""
    reason = selftest_signal()
    if reason is None:
        return None
    return reason if _same_path(path, live_path) else None


def flow_authority_write_blocked(path: str) -> Optional[str]:
    """selftest_blocks_live_write() bound to the live flow-authority.json — the one
    call a marker writer needs: `if reason: log + return` before it opens the file.

    A fixture marker there is not just noise: readers DEFER their Mayor mail while
    an unexpired marker exists, so a selftest that overwrites it either mutes them
    (fixture unexpired) or erases a real marker (fixture expired) — it changes
    production escalation behaviour, unlike a stray ledger row."""
    return selftest_blocks_live_write(path, LIVE_FLOW_AUTHORITY_FILE)


def _cleanup_scratch() -> None:
    global _scratch_dir
    d, _scratch_dir = _scratch_dir, None
    if d:
        shutil.rmtree(d, ignore_errors=True)


def _scratch_ledger_dir(reason: str) -> str:
    """The per-process throwaway ledger dir a test run is diverted into."""
    global _scratch_dir, _announced
    with _scratch_lock:  # two threads' first appends must not each mint a dir
        if _scratch_dir is None:
            try:
                _scratch_dir = tempfile.mkdtemp(prefix="gc-ledger-selftest-")
            except OSError as exc:
                # Under a positive test signal the LIVE dir is the one place we
                # must not fall back to. Inert: raise (fail_open callers swallow it).
                raise LedgerError(
                    f"{reason} but cannot create a scratch ledger dir ({exc}); "
                    f"refusing to fall back to the LIVE ledger dir"
                ) from exc
            atexit.register(_cleanup_scratch)
        if not _announced:
            _announced = True
            print(
                f"[gc_ledger] NOTICE: {reason} detected and the target is the LIVE "
                f"ledger dir — redirecting writes to {_scratch_dir} (live ledgers "
                f"untouched). Point GC_LEDGER_DIR at your own scratch dir to silence.",
                file=sys.stderr,
            )
        return _scratch_dir


def _effective_ledger_dir() -> str:
    """LEDGER_DIR, unless a positive test signal would make it hit production."""
    reason = selftest_signal()
    if reason is not None and _same_path(LEDGER_DIR, LIVE_LEDGER_DIR):
        return _scratch_ledger_dir(reason)
    return LEDGER_DIR


def ledger_path(ledger_name: str) -> str:
    """Return the full path to the named ledger file (follows a selftest redirect)."""
    return str(Path(_effective_ledger_dir()) / f"{ledger_name}.jsonl")


def gc_ledger_append(
    ledger_name: str,
    data: Union[dict, str],
    *,
    fail_open: bool = False,
) -> None:
    """Append one JSON line to the named ledger atomically.

    Args:
        ledger_name: base name (no path, no extension), e.g. "flow-ledger"
        data: dict to serialize, OR a pre-serialized JSON string
        fail_open: if True, catch LedgerError and return None instead of raising

    Raises:
        LedgerError: if fail_open is False and the write fails
        ValueError: if data is not a dict or str
    """
    try:
        _gc_ledger_append_inner(ledger_name, data)
    except LedgerError:
        if fail_open:
            print(
                f"[gc_ledger] WARN: write failed for {ledger_name!r} (fail_open=True, continuing)",
                file=sys.stderr,
            )
            return
        raise


def _gc_ledger_append_inner(ledger_name: str, data: Union[dict, str]) -> None:
    if not ledger_name or not isinstance(ledger_name, str):
        raise LedgerError("ledger_name must be a non-empty string")

    # Serialize
    if isinstance(data, dict):
        try:
            line = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        except (TypeError, ValueError) as exc:
            raise LedgerError(f"cannot serialize data to JSON: {exc}") from exc
    elif isinstance(data, str):
        # Validate that it parses as JSON (catch garbage early)
        try:
            json.loads(data)
        except json.JSONDecodeError as exc:
            raise LedgerError(f"data string is not valid JSON: {exc}") from exc
        line = data
    else:
        raise LedgerError(f"data must be dict or str, got {type(data).__name__!r}")

    # Strip any embedded newlines — each ledger line MUST be exactly one line
    line = line.replace("\n", " ").replace("\r", " ")

    # Resolve the target dir ONCE, through the selftest guard, BEFORE anything can
    # mkdir/open it — a test run must not so much as create the live dir.
    ledger_dir = _effective_ledger_dir()

    # Ensure ledger directory exists
    try:
        Path(ledger_dir).mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LedgerError(f"cannot create ledger dir {ledger_dir!r}: {exc}") from exc

    fpath = str(Path(ledger_dir) / f"{ledger_name}.jsonl")

    # Single atomic O_APPEND write.
    # O_WRONLY | O_CREAT | O_APPEND on POSIX guarantees each write() positions
    # atomically at EOF before writing. The write is atomic for sizes ≤ PIPE_BUF.
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    try:
        fd = os.open(fpath, flags, 0o644)
    except OSError as exc:
        raise LedgerError(f"cannot open ledger {fpath!r}: {exc}") from exc

    try:
        payload = (line + "\n").encode("utf-8")
        os.write(fd, payload)
    except OSError as exc:
        raise LedgerError(f"cannot write to ledger {fpath!r}: {exc}") from exc
    finally:
        os.close(fd)


# ── standalone / selftest entry point ─────────────────────────────────────────
def _selftest() -> int:
    import tempfile
    import threading

    global LEDGER_DIR

    PASS = 0
    FAIL = 0

    def ok(msg: str) -> None:
        nonlocal PASS
        PASS += 1
        print(f"  PASS: {msg}")

    def bad(msg: str) -> None:
        nonlocal FAIL
        FAIL += 1
        print(f"  FAIL: {msg}")

    print("=== gc_ledger.py --selftest ===")

    with tempfile.TemporaryDirectory() as tmp:
        LEDGER_DIR = tmp

        # T1: basic append — creates file, line is valid JSON
        gc_ledger_append("test-ledger", {"ts": "2026-06-23T10:00:00Z", "event": "t1"})
        fpath = ledger_path("test-ledger")
        if Path(fpath).exists():
            ok("T1a: ledger file created")
        else:
            bad("T1a: ledger file not created")

        with open(fpath) as f:
            content = f.read().strip()
        try:
            json.loads(content)
            ok("T1b: line parses as JSON")
        except json.JSONDecodeError:
            bad("T1b: line does not parse as JSON")

        # T2: two appends → 2 lines
        gc_ledger_append("test-ledger", {"ts": "2026-06-23T10:00:01Z", "event": "t2"})
        with open(fpath) as f:
            lines = [l for l in f.read().splitlines() if l.strip()]
        if len(lines) == 2:
            ok("T2: two lines after two appends")
        else:
            bad(f"T2: expected 2 lines, got {len(lines)}")

        # T3: each line valid JSON (JSONL)
        bad_lines = 0
        for ln in lines:
            try:
                json.loads(ln)
            except json.JSONDecodeError:
                bad_lines += 1
        if bad_lines == 0:
            ok("T3: all lines parse as JSON (JSONL valid)")
        else:
            bad(f"T3: {bad_lines} line(s) fail JSON parse")

        # T4: string data (pre-serialized JSON)
        gc_ledger_append("str-ledger", '{"ts":"2026-06-23T10:00:02Z","event":"str"}')
        sp = ledger_path("str-ledger")
        with open(sp) as f:
            sl = f.read().strip()
        try:
            json.loads(sl)
            ok("T4: string data accepted and parses as JSON")
        except json.JSONDecodeError:
            bad("T4: string data does not parse as JSON")

        # T5: invalid JSON string is rejected
        try:
            gc_ledger_append("bad-ledger", "not json at all")
            bad("T5: should raise LedgerError on invalid JSON string")
        except LedgerError:
            ok("T5: invalid JSON string raises LedgerError")

        # T6: fail_open=True swallows errors
        try:
            gc_ledger_append("bad-ledger2", "not json", fail_open=True)
            ok("T6: fail_open=True swallows LedgerError")
        except LedgerError:
            bad("T6: fail_open=True should not raise")

        # T7: embedded newlines stripped → exactly 1 line
        gc_ledger_append("newline-ledger", {"msg": "line1\nline2", "ts": "t"})
        np = ledger_path("newline-ledger")
        with open(np) as f:
            nl_count = len([l for l in f.read().splitlines() if l.strip()])
        if nl_count == 1:
            ok("T7: embedded newlines stripped → exactly 1 line")
        else:
            bad(f"T7: expected 1 line, got {nl_count}")

        # T8: concurrent writes → all lines valid, correct count
        N = 20
        errors: list[str] = []

        def write_one(i: int) -> None:
            try:
                gc_ledger_append(
                    "concurrent-ledger",
                    {"ts": f"2026-06-23T10:00:{i:02d}Z", "seq": i},
                )
            except LedgerError as e:
                errors.append(str(e))

        threads = [threading.Thread(target=write_one, args=(i,)) for i in range(N)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        cp = ledger_path("concurrent-ledger")
        with open(cp) as f:
            clines = [l for l in f.read().splitlines() if l.strip()]
        if len(clines) == N and not errors:
            ok(f"T8a: concurrent appends → correct line count ({N})")
        else:
            bad(f"T8a: expected {N} lines, got {len(clines)}; errors={errors}")

        cbad = 0
        for ln in clines:
            try:
                json.loads(ln)
            except json.JSONDecodeError:
                cbad += 1
        if cbad == 0:
            ok("T8b: all concurrent lines parse as JSON (no partial writes)")
        else:
            bad(f"T8b: {cbad} partial/invalid lines from concurrent writes")

        # T9: ledger_path returns correct path
        expected = os.path.join(tmp, "my-ledger.jsonl")
        got = ledger_path("my-ledger")
        if got == expected:
            ok("T9: ledger_path returns correct .jsonl path")
        else:
            bad(f"T9: ledger_path: expected {expected!r}, got {got!r}")

    print(f"\n=== RESULT: PASS={PASS} FAIL={FAIL} ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(_selftest())
    elif len(sys.argv) >= 3:
        name = sys.argv[1]
        payload = sys.argv[2]
        gc_ledger_append(name, payload)
    else:
        print("Usage: gc_ledger.py <ledger-name> <json-string>", file=sys.stderr)
        print("       gc_ledger.py --selftest", file=sys.stderr)
        sys.exit(1)
