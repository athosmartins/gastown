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
  ledger_path(ledger_name) -> str — full path to the .jsonl file

Usage:
  from gc_ledger import gc_ledger_append, LEDGER_DIR
  gc_ledger_append("flow-ledger", {"ts": "2026-06-23T10:00:00Z", "event": "snapshot"})
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Union

# ── config ────────────────────────────────────────────────────────────────────
LEDGER_DIR: str = os.environ.get(
    "GC_LEDGER_DIR",
    "/Users/athos/gt/.gascity-gastown-hq/.gc/logs",
)


class LedgerError(RuntimeError):
    """Raised when a ledger write fails (unless fail_open=True)."""


def ledger_path(ledger_name: str) -> str:
    """Return the full path to the named ledger file."""
    return str(Path(LEDGER_DIR) / f"{ledger_name}.jsonl")


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

    # Ensure ledger directory exists
    try:
        Path(LEDGER_DIR).mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LedgerError(f"cannot create ledger dir {LEDGER_DIR!r}: {exc}") from exc

    fpath = ledger_path(ledger_name)

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
