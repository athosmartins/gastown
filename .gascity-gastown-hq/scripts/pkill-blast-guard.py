#!/usr/bin/env python3
"""pkill-blast-guard.py (ga-jo3xl) — PreToolUse:Bash guard against dangerous
pkill/killall invocations.

WHY: 2026-07-28 18:30, batista-wa ran `pkill -f "anuncios_dashboard.py" -U
$(id -u)`. On BSD pkill/pgrep (macOS) the PATTERN must be the LAST argument
-- with it placed before -U, the match becomes ~every process the user owns
instead of the two intended. This SIGTERM'd 8 claude sessions plus the
production anuncios-dashboard daemon in the same second. See bead ga-jo3xl.

STRUCTURE (fix-attempt 3): the first two fix attempts each closed one
specific bypass a gate reviewer found (glued separators, then unexpanded
variables), and each time a DIFFERENT gap in the same allow-by-default shape
let a THIRD bypass through (a criteria-only invocation like `pkill -U 501`,
no pattern operand at all -- BSD reads that as the WIDEST possible match,
not a safe default). Per Mayor's review: the fix isn't another patched
case, it's inverting the default. Once a command is confirmed to contain a
pkill/killall invocation, every path from here on is
DENY-UNLESS-VERIFIED-SAFE, never allow-unless-proven-dangerous. All of the
following now deny rather than fall through to the old default:
  - a flag placed after the first pattern/target operand (the original
    defect -- BSD requires all flags before all operands);
  - NO pattern/target operand at all, only criteria flags like -U/-u;
  - a pattern containing unexpanded shell variable/substitution syntax
    ($VAR, ${VAR}, $(...), a backtick);
  - pgrep itself failing/timing out while checking a pattern;
  - this script's own tokenizer failing to parse a command the coarse
    pre-filter already confirmed mentions pkill/killall -- a genuine
    "cannot verify," which is NOT the same as this SCRIPT crashing (see
    FAIL-OPEN below);
  - running out of the analysis time budget with invocations still
    unchecked (previously: silently stopped checking and allowed).
One case is DELIBERATELY NOT a deny, despite looking similar at first
glance: a command whose raw text happens to contain the word "pkill"/
"killall" (e.g. this file's own name, `scripts/pkill-blast-guard.py`, or a
commit message that mentions "pkill") but which the tokenizer -- cleanly,
without error -- determines contains no actual pkill/killall invocation.
Denying there would mean nobody could ever `cat`, `git commit -m`, or
`grep` anything mentioning this guard's own name without tripping it; see
split_operands_and_flags / find_invocations for why the exact-basename
tokenizer match is trustworthy on its own once it completes without error,
and the (narrower) tokenizer-FAILURE case above for the actual residual gap
this closes instead.

WHAT: reads a single Claude Code PreToolUse hook payload from stdin. When
tool_name is "Bash" and tool_input.command contains a pkill/killall
invocation -- including one glued flush against a preceding ;/&&/||/|/&
with no whitespace, e.g. "echo hi;pkill ..." -- denies per the rules above.
killall's documented multi-target form (`killall firefox slack`) is treated
as multiple legitimate targets, each individually checked below -- NOT as a
single pattern followed by a stray flag (that was itself a false-positive
a gate reviewer found: `killall firefox slack` was denied as though "slack"
were a misplaced flag).
  (a) the pattern/first target is not the last operand -- i.e. a flag
      appears after it -- the exact defect behind ga-jo3xl's incident,
      checked by pure argv inspection;
  (b) no pattern/target operand is present at all (criteria-only, e.g.
      `pkill -U 501`);
  (c) a pattern contains unexpanded shell variable/substitution syntax;
  (d) a pattern currently matches any process whose command line contains
      "claude" (checked read-only via `pgrep -fl`);
  (e) a pattern currently matches more than N processes (default 5,
      override via PKILL_GUARD_MAX_MATCHES);
  (f) pgrep itself fails or times out while checking (d)/(e).
Every other command -- including plain `kill $PID` -- is allowed untouched.
Only pkill/killall invocations are ever inspected; the candidate command
itself is never executed by this guard.

A `$(...)` or `` `...` `` command substitution used as a CRITERIA FLAG's
value (e.g. `-U $(id -u)`, this guard's own suggested safe rewrite of the
incident line) is treated as one opaque value, not shattered into stray
operands by the punctuation-aware tokenizer -- see
_protect_command_substitutions. Without this, the guard's own "correct
form" suggestion in the deny message below would itself get denied.

FAIL-OPEN (AC4, narrowly): an exception in THIS SCRIPT unrelated to a
specific dangerous-looking input (e.g. a coding bug, a malformed JSON
payload, a bad PKILL_GUARD_MAX_MATCHES env value) results in an explicit
"allow" -- a guard that breaks and denies everything is worse than the
incident it prevents. This is NOT the same as "the input's shell syntax
couldn't be parsed": when the coarse pre-filter has already confirmed the
raw command mentions pkill/killall and the tokenizer then fails on it (e.g.
unbalanced quotes), that is a "cannot verify this specific command" RESULT,
and per the inversion above, an unverifiable result denies rather than
silently passing as safe.

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

# Opaque placeholder for a protected $(...) / `...` span -- NUL-delimited so
# it can never collide with real command text (NUL can't appear in a shell
# command string) and contains no shell-meaningful or flag-shaped character.
_CMDSUB_PLACEHOLDER = "\x00CMDSUB%d\x00"
_CMDSUB_PLACEHOLDER_RE = re.compile(r"\x00CMDSUB\d+\x00")


def _protect_command_substitutions(command):
    """Replace each balanced $(...) or `...` span in `command` with an
    opaque placeholder, BEFORE tokenizing. Without this, `-U $(id -u)` --
    extremely common as a criteria-flag value, and this guard's OWN
    suggested rewrite of the incident line -- gets shattered by the
    punctuation-aware tokenizer below (it splits on bare "(" / ")" too, to
    catch e.g. "(pkill ...)" glued against a subshell paren with no space),
    scattering '$', '(', 'id', '-u', ')' as five separate tokens that then
    get misread as bogus extra operands/flags. Returns (protected_command,
    placeholders) where placeholders maps each placeholder back to its
    original raw text -- _tokenize restores every token before returning it,
    so a pattern that IS itself a substitution (as opposed to some OTHER
    flag's value) still reads as unexpanded/unverifiable rather than as an
    inert placeholder string pgrep would confirm "safe" by finding zero
    matches for. Raises ValueError on an unbalanced span -- caller treats
    that the same as any other tokenizer failure (deny, not fail-open; see
    module docstring)."""
    out = []
    placeholders = {}
    i, n, counter = 0, len(command), 0
    while i < n:
        ch = command[i]
        if ch == "$" and i + 1 < n and command[i + 1] == "(":
            depth = 1
            j = i + 2
            while j < n and depth > 0:
                if command[j] == "(":
                    depth += 1
                elif command[j] == ")":
                    depth -= 1
                j += 1
            if depth != 0:
                raise ValueError("unbalanced $(...) in command")
            key = _CMDSUB_PLACEHOLDER % counter
            placeholders[key] = command[i:j]
            out.append(key)
            counter += 1
            i = j
        elif ch == "`":
            j = command.find("`", i + 1)
            if j == -1:
                raise ValueError("unbalanced ` in command")
            key = _CMDSUB_PLACEHOLDER % counter
            placeholders[key] = command[i:j + 1]
            out.append(key)
            counter += 1
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), placeholders


def _restore(token, placeholders):
    if placeholders and _CMDSUB_PLACEHOLDER_RE.search(token):
        for key, raw in placeholders.items():
            token = token.replace(key, raw)
    return token


def _tokenize(command):
    """Tokenize like shlex.split, but also split shell control operators
    (;, &&, ||, |, &) into their own tokens even when glued flush against a
    neighboring word with no whitespace (e.g. "echo hi;pkill ..."). Plain
    shlex.split only splits on whitespace, so a glued separator leaves the
    next command's name fused onto it as one token (e.g. "hi;pkill") that
    never matches the "pkill"/"killall" basename check in find_invocations
    -- silently hiding that entire invocation from the guard. Quoting still
    protects separator characters that are genuinely part of a pattern
    (e.g. 'foo;bar' stays one token); this only affects unquoted operators.
    $(...)/`...` spans are protected first (see
    _protect_command_substitutions) and restored per-token after shlex has
    decided token boundaries, so a command-substitution value survives as
    one token instead of being shattered by the same punctuation splitting."""
    protected, placeholders = _protect_command_substitutions(command)
    lexer = shlex.shlex(protected, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return [_restore(tok, placeholders) for tok in lexer]


def find_invocations(command):
    """Yield the argv list following each pkill/killall command-word
    occurrence in `command`, each cut off at the next shell separator token
    (;, &&, ||, |, &) or end of string. Raises on unparseable input
    (unbalanced quotes/parens/backticks) -- caller treats that as a
    verification failure on a command already confirmed (by the caller's
    coarse pre-filter) to mention pkill/killall, i.e. it denies rather than
    assuming unparseable means safe."""
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


def split_operands_and_flags(args):
    """Walk `args` (the tokens following a pkill/killall command word).
    Returns (operands, flag_after_operand): `operands` is the ordered list
    of non-flag tokens -- pattern/target candidates; killall's documented
    `killall [procname ...]` form allows more than one, so this collects
    ALL of them rather than assuming exactly one. `flag_after_operand` goes
    True the moment any flag-shaped token appears AFTER the first operand
    has been seen -- BSD pkill/killall requires every flag before every
    operand, so a flag there is rule (a)'s exact defect regardless of how
    many operands came before it (a second plain operand, e.g. killall's
    "slack" after "firefox", is NOT a flag and must not trip this). A token
    in ARG_TAKING_FLAGS consumes the next token as its value (never counted
    as an operand itself, e.g. `-U 501` contributes zero operands)."""
    operands = []
    flag_after_operand = False
    i, n = 0, len(args)
    while i < n:
        tok = args[i]
        if tok.startswith("-") and tok != "-":
            if operands:
                flag_after_operand = True
            i += 2 if tok in ARG_TAKING_FLAGS else 1
            continue
        operands.append(tok)
        i += 1
    return operands, flag_after_operand


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


def check_pattern(pattern, max_matches):
    """Run rules (c)/(d)/(e)/(f) against a single pattern/target. Returns a
    deny reason string, or None if this pattern alone is clean."""
    if pattern_unverifiable(pattern):
        return (
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
        return (
            "pkill/killall pattern %r could not be verified -- pgrep "
            "itself failed or timed out, so this guard cannot confirm "
            "whether it's safe. Refusing rather than treating 'could "
            "not check' as 'verified safe'. Validate manually with "
            "`pgrep -lf %r` before retrying."
            % (pattern, pattern)
        )

    if any("claude" in line.lower() for line in matches):
        return (
            "pkill/killall pattern %r currently matches a `claude` "
            "process on this machine -- refusing (this is exactly how "
            "ga-jo3xl's incident took down 8 sessions). Validate first: "
            "`pgrep -lf %r`. Use a pattern that cannot collide with a "
            "claude session or daemon (a port, a scratchpad path, or "
            "the PID from your own nohup's $!)." % (pattern, pattern)
        )

    if len(matches) > max_matches:
        return (
            "pkill/killall pattern %r currently matches %d processes "
            "(> %d) -- refusing as too broad. Validate first: "
            "`pgrep -lf %r`. Narrow the pattern (full path, a unique "
            "port/env marker) or kill by PID instead."
            % (pattern, len(matches), max_matches, pattern)
        )

    return None


def decide(command, max_matches):
    if not CMD_RE.search(command):
        return "allow", None

    try:
        invocations = list(find_invocations(command))
    except Exception as exc:
        # The coarse pre-filter (CMD_RE, just above) already confirmed this
        # command mentions pkill/killall; the tokenizer that's supposed to
        # turn that into a concrete, checkable invocation just failed on
        # it. That's a "cannot verify" RESULT about this specific command,
        # not this SCRIPT breaking (AC4's narrower fail-open) -- unknown
        # result denies, same principle as an unverifiable pattern below.
        return "deny", (
            "This command mentions pkill/killall, but its shell syntax "
            "could not be parsed to verify what it would actually do "
            "(%s: %s) -- refusing rather than assuming an unparseable "
            "command is safe. Simplify the quoting/escaping, or run the "
            "read-only `pgrep -lf <same args>` first to confirm by hand."
            % (type(exc).__name__, exc)
        )

    if not invocations:
        # CMD_RE matched somewhere in the raw text (a filename, a branch
        # name, a commit message mentioning "pkill"/"killall"...) but the
        # tokenizer -- cleanly, no exception -- found no actual pkill/
        # killall command-word token. Trustworthy: find_invocations already
        # matches by exact basename over every token in the whole stream
        # regardless of position (catches `sudo pkill`, `nohup pkill`,
        # etc.), and the only way a real invocation could hide from that
        # is a tokenizer/parse FAILURE, which is handled above as a deny.
        # Denying here too would mean `cat scripts/pkill-blast-guard.py` or
        # `git commit -m "fix pkill guard"` could never run again.
        return "allow", None

    deadline = time.monotonic() + OVERALL_BUDGET_SECS
    for args in invocations:
        if time.monotonic() > deadline:
            # Ran long with invocations still left to verify -- an
            # un-checked pkill/killall is exactly the "unknown result"
            # case, so this denies rather than silently stopping early and
            # allowing the unchecked remainder through.
            return "deny", (
                "pkill/killall: this command has multiple invocations to "
                "verify and ran out of the guard's analysis time budget "
                "before finishing -- refusing rather than allowing the "
                "unchecked remainder through. Split this into separate "
                "commands, or validate manually with `pgrep -lf`."
            )

        operands, flag_after_operand = split_operands_and_flags(args)

        if flag_after_operand:
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

        if not operands:
            return "deny", (
                "pkill/killall with NO pattern/target operand -- only "
                "criteria flags like -U/-u/-G/-g/-P/-t -- matches EVERY "
                "process satisfying those criteria. On BSD pkill/killall "
                "(macOS), an absent pattern is the WIDEST possible match, "
                "not a safe default: `pkill -U $(id -u)` or `pkill -u "
                "root` reaches the identical blast radius as ga-jo3xl's "
                "misordered-flag incident (8 claude sessions + a "
                "production daemon) through an even more natural-looking "
                "shortcut. Got: pkill " + " ".join(args) + ". Supply an "
                "explicit pattern/procname and validate first with "
                "`pgrep -lf <same args>`, or kill by PID instead."
            )

        for pattern in operands:
            reason = check_pattern(pattern, max_matches)
            if reason:
                return "deny", reason

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
        # AC4: FAIL OPEN, narrowly -- this catches bugs in THIS SCRIPT (a
        # malformed JSON payload, a bad PKILL_GUARD_MAX_MATCHES value, an
        # actual coding error) that are unrelated to any specific dangerous
        # command shape. decide() itself never raises for a pkill/killall-
        # mentioning command -- its own tokenizer failures are caught
        # inside decide() and turned into an explicit deny, per the
        # inversion described in the module docstring.
        pass


if __name__ == "__main__":
    main()
