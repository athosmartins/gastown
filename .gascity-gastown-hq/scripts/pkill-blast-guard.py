#!/usr/bin/env python3
"""pkill-blast-guard.py (ga-jo3xl) — PreToolUse:Bash guard against dangerous
pkill/killall invocations.

WHY: 2026-07-28 18:30, batista-wa ran `pkill -f "anuncios_dashboard.py" -U
$(id -u)`. On BSD pkill/pgrep (macOS) the PATTERN must be the LAST argument
-- with it placed before -U, the match becomes ~every process the user owns
instead of the two intended. This SIGTERM'd 8 claude sessions plus the
production anuncios-dashboard daemon in the same second. See bead ga-jo3xl.

WHAT: reads a single Claude Code PreToolUse hook payload from stdin. When
tool_name is "Bash" and tool_input.command contains a pkill/killall
invocation -- including one glued flush against a preceding ;/&&/||/|/&
with no whitespace, e.g. "echo hi;pkill ..." -- denies when:
  (a) the pattern is not the last argument (a flag or its value follows it)
      -- the exact defect above, checked by pure argv inspection;
  (b) the pattern contains unexpanded shell variable/substitution syntax
      ($VAR, ${VAR}, $(...), a backtick) -- checking the literal text
      against the process table would prove nothing about what the pattern
      actually expands to at runtime, so this is refused rather than
      silently read as "confirmed safe";
  (c) the pattern currently matches any process whose command line contains
      "claude" (checked read-only via `pgrep -fl`);
  (d) the pattern currently matches more than N processes (default 5,
      override via PKILL_GUARD_MAX_MATCHES);
  (e) pgrep itself fails or times out while checking (c)/(d) -- a genuine
      "cannot verify" is never treated the same as a confirmed-safe read.
Every other command -- including plain `kill $PID` -- is allowed untouched.
Only pkill/killall invocations are ever inspected; the candidate command
itself is never executed by this guard.

FAIL-OPEN (AC4): any internal error, unparseable input, or pgrep timeout
anywhere in this script results in an explicit "allow" -- a guard that
breaks and denies everything is worse than the incident it prevents.

TEST: bash scripts/pkill-blast-guard.selftest.sh
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

MAX_MATCHES_DEFAULT = 5
PGREP_TIMEOUT_SECS = 0.5
OVERALL_BUDGET_SECS = 0.9  # stays under the <1s budget (AC4) with margin

# BSD pkill/killall flags that consume the NEXT token as a value (space-
# separated, e.g. `-U 501`, never glued). Every other `-x`-shaped token is
# treated as a standalone boolean flag (-f, -v, -x, -9, -e, -i, ...).
# -F (pidfile) and -j (jail, FreeBSD-only but harmless to include) also take
# a value; missing them let `pkill -F file.pid -f X` misfire rule (a), since
# the pidfile path would be mistaken for the pattern.
ARG_TAKING_FLAGS = {"-t", "-u", "-U", "-g", "-G", "-P", "-d", "-s", "-F", "-j"}

CMD_RE = re.compile(r"\b(pkill|killall)\b")
# Includes bare "&" (backgrounding) alongside the compound/pipe operators --
# same class of shell control token as ";"/"&&"/"||"/"|", and a pkill/killall
# glued flush against any of these with no whitespace must still be split
# into its own invocation (see _tokenize below), not swallowed into the
# neighboring command's argument list.
SEPARATORS = (";", "&&", "||", "|", "&")


def _tokenize(command):
    """Tokenize like shlex.split, but also split shell control operators
    (;, &&, ||, |, &) into their own tokens even when glued flush against a
    neighboring word with no whitespace (e.g. "echo hi;pkill ..."). Plain
    shlex.split only splits on whitespace, so a glued separator leaves the
    next command's name fused onto it as one token (e.g. "hi;pkill") that
    never matches the "pkill"/"killall" basename check in find_invocations
    -- silently hiding that entire invocation from the guard. Quoting still
    protects separator characters that are genuinely part of a pattern
    (e.g. 'foo;bar' stays one token); this only affects unquoted operators."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def find_invocations(command):
    """Yield the argv list following each pkill/killall command-word
    occurrence in `command`, each cut off at the next shell separator token
    (;, &&, ||, |, &) or end of string. Raises on unparseable input
    (unbalanced quotes) -- caller is responsible for failing open."""
    tokens = _tokenize(command)
    n = len(tokens)
    i = 0
    while i < n:
        tok = tokens[i]
        if os.path.basename(tok) in ("pkill", "killall"):
            args = []
            j = i + 1
            while j < n and tokens[j] not in SEPARATORS:
                args.append(tokens[j])
                j += 1
            yield args
            i = j
        else:
            i += 1


def first_operand_index(args):
    """Index of the first token in `args` that isn't a flag or a flag's
    value (honoring ARG_TAKING_FLAGS, which also consumes the next token).
    None if every token is flag-shaped."""
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]
        if tok.startswith("-") and tok != "-":
            i += 2 if tok in ARG_TAKING_FLAGS else 1
            continue
        return i
    return None


def pattern_not_last(args):
    idx = first_operand_index(args)
    return idx is not None and idx < len(args) - 1


def extract_pattern(args):
    idx = first_operand_index(args)
    return args[idx] if idx is not None else None


UNVERIFIABLE_PATTERN_RE = re.compile(r"\$\{|\$\(|\$[A-Za-z_]|`")


def pattern_unverifiable(pattern):
    """True if `pattern` contains unexpanded shell variable/substitution
    syntax ($VAR, ${VAR}, $(...), or a backtick command substitution).
    pgrep would match this LITERALLY against the current process table --
    e.g. checking the literal text "$TARGET" finds ~zero matches on any
    real machine, which looks like "confirmed safe" but says nothing about
    what killing "$TARGET" will actually match once the shell expands it at
    runtime. Collapsing that unknown into a confirmed-safe read is the same
    error-vs-empty bug class as the pgrep_matches None/[] distinction below
    -- this function exists so decide() can tell the two apart too."""
    return bool(UNVERIFIABLE_PATTERN_RE.search(pattern))


def pgrep_matches(pattern):
    """Read-only: (pid, command-line) lines matching `pattern` via
    `pgrep -fl`. Returns None (never []) on any failure/timeout so the
    caller can distinguish "confirmed zero matches" from "couldn't check" --
    the latter must never silently pass as "0 matches"."""
    try:
        proc = subprocess.run(
            ["pgrep", "-fl", pattern],
            capture_output=True, text=True, timeout=PGREP_TIMEOUT_SECS,
        )
    except Exception:
        return None
    if proc.returncode not in (0, 1):  # 1 == no matches, still a clean read
        return None
    return [line for line in proc.stdout.splitlines() if line.strip()]


def decide(command, max_matches):
    deadline = time.monotonic() + OVERALL_BUDGET_SECS
    for args in find_invocations(command):
        if time.monotonic() > deadline:
            break  # ran long on a pathological multi-invocation command; stop checking further ones (fail-open for the rest)

        if pattern_not_last(args):
            return "deny", (
                "pkill/killall: PATTERN must be the LAST argument. On BSD "
                "pkill (macOS), a flag placed after the pattern makes the "
                "match ~every process you own instead of the intended one "
                "-- the exact defect behind ga-jo3xl's 2026-07-28 incident, "
                "which SIGTERM'd 8 claude sessions plus a production "
                "daemon. Got: pkill " + " ".join(args) + ". Correct form: "
                "every flag and its value BEFORE the pattern, pattern last "
                "-- e.g. `pkill -f -U $(id -u) 'PATTERN'`. Validate first "
                "with the read-only `pgrep -lf <same args>` before ever "
                "running pkill. Prefer killing a test process by its own "
                "nohup PID ($!) or by a discriminant pattern (port or "
                "scratchpad path) rather than a basename shared with "
                "production."
            )

        pattern = extract_pattern(args)
        if not pattern:
            continue

        if pattern_unverifiable(pattern):
            return "deny", (
                "pkill/killall pattern %r contains unexpanded shell "
                "variable/substitution syntax ($VAR, ${VAR}, $(...), or a "
                "backtick) -- this guard can only check the LITERAL text "
                "against the current process table, not whatever the shell "
                "actually expands it to when the command runs, so a clean "
                "read here proves nothing about what will really get "
                "killed. Refusing rather than silently treating 'could not "
                "verify' as 'verified safe'. Expand the variable yourself "
                "and re-run `pgrep -lf <expanded-pattern>` to confirm what "
                "it actually matches, or use a literal pattern instead."
                % pattern
            )

        matches = pgrep_matches(pattern)
        if matches is None:
            # pgrep itself failed/timed out -- a legitimate "cannot verify"
            # result (AC4's fail-open covers this SCRIPT erroring, not an
            # external check coming back inconclusive), so this must not
            # silently fall through to the same "allow" a confirmed-zero-
            # matches read would produce.
            return "deny", (
                "pkill/killall pattern %r could not be verified -- pgrep "
                "itself failed or timed out, so this guard cannot confirm "
                "whether it's safe. Refusing rather than treating 'could "
                "not check' as 'verified safe'. Validate manually with "
                "`pgrep -lf %r` before retrying."
                % (pattern, pattern)
            )

        if any("claude" in line.lower() for line in matches):
            return "deny", (
                "pkill/killall pattern %r currently matches a `claude` "
                "process on this machine -- refusing (this is exactly how "
                "ga-jo3xl's incident took down 8 sessions). Validate first: "
                "`pgrep -lf %r`. Use a pattern that cannot collide with a "
                "claude session or daemon (a port, a scratchpad path, or "
                "the PID from your own nohup's $!)." % (pattern, pattern)
            )

        if len(matches) > max_matches:
            return "deny", (
                "pkill/killall pattern %r currently matches %d processes "
                "(> %d) -- refusing as too broad. Validate first: "
                "`pgrep -lf %r`. Narrow the pattern (full path, a unique "
                "port/env marker) or kill by PID instead."
                % (pattern, len(matches), max_matches, pattern)
            )

    return "allow", None


def emit(decision, reason):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
        }
    }
    if reason:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    print(json.dumps(out))


def main():
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") != "Bash":
            emit("allow", None)
            return

        command = payload.get("tool_input", {}).get("command") or ""
        if not command or not CMD_RE.search(command):
            emit("allow", None)
            return

        # Selftest-only fault injection (AC4 proof): never set in production.
        if os.environ.get("PKILL_GUARD_SELFTEST_FORCE_ERROR") == "1":
            raise RuntimeError("selftest-forced error to prove the fail-open path")

        max_matches = int(os.environ.get("PKILL_GUARD_MAX_MATCHES", MAX_MATCHES_DEFAULT))
        decision, reason = decide(command, max_matches)
        emit(decision, reason)
    except Exception:
        # AC4: FAIL OPEN. No output, exit 0 -- Claude Code treats a hook
        # with no explicit decision as "no opinion", so the tool proceeds.
        pass


if __name__ == "__main__":
    main()
