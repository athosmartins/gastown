#!/usr/bin/env python3
"""pkill-blast-guard.py (ga-tje7u, supersedes ga-jo3xl) -- PreToolUse:Bash
guard against pkill/killall.

WHY: 2026-07-28, a misordered pkill flag (`pkill -f PATTERN -U $(id -u)` --
BSD requires PATTERN last) SIGTERM'd 8 claude sessions plus a production
daemon in one shot (bead ga-jo3xl). The first fix analyzed each
pkill/killall invocation's pattern and flags, denying specific dangerous
shapes. Six review rounds each found a DIFFERENT bypass the analysis
missed (glued separators, unexpanded $VAR, criteria-only calls, "man
pkill" false positives, a machine-dependent pgrep-match accident, redirect
operators misread as pattern operands) -- the analysis itself was the risk
surface, wide open to whatever subtlety nobody had thought of yet.

DESIGN: ONE rule. If pkill or killall appears in COMMAND POSITION in a
Bash tool call, deny -- always, regardless of pattern, flags, or what
pgrep would say. No pattern parsing, no subprocess calls, no "safe form"
this guard recognizes.

THREAT MODEL: accident, not adversary (the ga-jo3xl author didn't evade
anything -- it was a genuine mistake). This guard makes no attempt to
resist deliberate evasion -- `pgrep | xargs kill` walks straight past it,
same as wrapping the call in `bash -c '...'` or a command substitution --
and that is an accepted, documented gap, not an oversight.

SCOPE: intercepts only the Bash tool calls of Claude Code AGENTS running
under this hook. Daemons, launchd jobs, and .sh scripts invoked outside an
agent's Bash tool never pass through this hook -- e.g.
adb_usb_recover.sh's own `pkill -9 -f 'adb.*fork-server'` is unaffected.

COMMAND POSITION: pkill/killall counts as a real invocation -- not a plain
argument to some other command (`man pkill`, `echo pkill`) -- when EITHER:
  (a) it's the first word of a simple command: start of the whole string,
      or immediately after a separator (; && || | &), an opening `(` or
      `{`, or a newline (converted to `;` before tokenizing -- shell
      treats an unquoted newline as an ordinary statement separator, but
      shlex just swallows it as whitespace and leaves no token behind);
  (b) every token between the start of its simple command and it is
      consistent with a chain of known wrapper commands (sudo, doas,
      nohup, env, time, xargs, exec, command, !) and/or inline VAR=value
      assignments, optionally followed by that wrapper's own flags (e.g.
      "sudo -u root pkill").
Deliberately NOT a rule: "pkill/killall has trailing arguments of its own,
regardless of what precedes it." An earlier draft used that rule instead
of the wrapper whitelist above specifically to avoid re-enumerating
wrappers (an enumeration is always incomplete) -- but it also means `grep
pkill file.sh` (pkill is grep's SEARCH TERM, not being invoked) and `man
pkill 2>/dev/null` (same shape) can never be told apart from `xargs pkill
-U 501` (pkill genuinely invoked) by token position alone; that requires
knowing what the preceding command actually DOES with its argument, which
only an explicit wrapper list can encode. Accepted tradeoff, the same
shape as the evasion gap above: an invocation behind an unenumerated
wrapper this list doesn't name slips through unflagged. Extend
WRAPPER_PREFIXES if a real gap is found -- do not go back to a blanket
"has trailing args" rule, it was tried and reverted for the reason above.

REDIRECTS (`>`, `<`, `>>`, `2>&1`, ...): no dedicated handling exists, and
none is needed. Because command position only ever looks BACKWARD from a
candidate pkill/killall token (never at what follows it), a trailing
redirect can't change the verdict either way: `pkill -U 501 2>/dev/null`
denies because pkill is still the first word, and `man pkill 2>/dev/null`
allows because "man" is still not a wrapper -- in both cases the redirect
is simply never inspected. (The prior pattern-analysis design DID look
forward, to find pkill's pattern operand, so a redirect operator
misclassified as that operand was a real bug there -- see ga-jo3xl. That
whole class of bug has no equivalent here because there's no operand
concept left to confuse.)

TEST: bash pkill-blast-guard.selftest.sh
"""
import json
import os
import re
import shlex
import sys

CMD_RE = re.compile(r"\b(pkill|killall)\b")
SEPARATORS = (";", "&&", "||", "|", "&")
COMMAND_START_TOKENS = SEPARATORS + ("(", "{")
WRAPPER_PREFIXES = {"sudo", "doas", "nohup", "env", "time", "xargs", "exec", "command", "!"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Opaque, NUL-delimited placeholder for a protected $(...)/`...` span -- NUL
# can't appear in a real shell command string, so this can never collide.
_CMDSUB_PLACEHOLDER = "\x00CMDSUB%d\x00"
_CMDSUB_PLACEHOLDER_RE = re.compile(r"\x00CMDSUB\d+\x00")

# Every operator shlex's punctuation_chars="();<>|&" mode can hand back as
# one fused token. Longest match first so e.g. "&&" isn't split into "&","&".
_KNOWN_OPERATORS = (
    "&&", "||", ">>", "<<", ">&", "&>", "<&", "<>",
    ";", "&", "|", "<", ">", "(", ")",
)
_PUNCTUATION_RUN_RE = re.compile(r"^[();<>|&]+$")


def _protect_command_substitutions(command):
    """Replace each balanced $(...)/`...` span with an opaque placeholder
    before tokenizing, so e.g. a wrapper's "-U $(id -u)" flag value
    survives as one token instead of being shattered -- an internal "("
    from a shattered substitution would otherwise be misread as a command
    start token. Raises ValueError on an unbalanced span; the caller
    treats that as a parse failure (deny, not fail-open -- see decide())."""
    out, placeholders = [], {}
    i, n, counter = 0, len(command), 0
    while i < n:
        ch = command[i]
        if ch == "$" and i + 1 < n and command[i + 1] == "(":
            depth, j = 1, i + 2
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


def _split_operator_run(tok):
    """shlex's punctuation_chars mode fuses adjacent operator characters
    into one token even when they're two DISTINCT operators with no space
    between them (e.g. "&;" -> one token, not "&" then ";"). Re-split any
    pure-punctuation token into the real operators it represents."""
    if not _PUNCTUATION_RUN_RE.match(tok):
        return [tok]
    out, i, n = [], 0, len(tok)
    while i < n:
        for op in _KNOWN_OPERATORS:
            if tok.startswith(op, i):
                out.append(op)
                i += len(op)
                break
        else:
            out.append(tok[i])
            i += 1
    return out


def _tokenize(command):
    """Shell-aware tokenizer: splits on whitespace and on shell
    control/redirect operators, even glued flush against a neighboring
    word (e.g. "echo hi;pkill ..."). An unquoted newline is a statement
    separator in real bash exactly like ";" -- shlex treats it as plain
    whitespace and drops it, so it's converted to ";" first to keep that
    meaning visible. Quoting still protects any operator character that's
    genuinely part of a pattern (e.g. 'foo;bar' stays one token)."""
    protected, placeholders = _protect_command_substitutions(command)
    protected = protected.replace("\r\n", ";").replace("\n", ";")
    lexer = shlex.shlex(protected, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = []
    for tok in lexer:
        tokens.extend(_split_operator_run(_restore(tok, placeholders)))
    return tokens


def _wrapper_chain(tokens, i):
    """True if every token between the start of tokens[i]'s simple command
    and tokens[i] is consistent with a chain of WRAPPER_PREFIXES commands
    and/or VAR=value assignments, optionally followed by that wrapper's
    own flags/flag-values once one has been seen (e.g. "-u root" after
    "sudo"). See the module docstring for why this is an explicit
    whitelist rather than "any preceding word".

    A bare word after a wrapper that is itself neither another
    wrapper/assignment nor flag-shaped (doesn't start with "-") nor the
    value of the flag right before it (that DOES start with "-") ends the
    chain instead of extending it: that word is the wrapper's actual
    target command, and if it isn't pkill/killall, whatever follows is
    THAT command's own arguments, not the wrapper's. Without this,
    `sudo echo pkill -U 501` (sudo running echo, which just prints its
    args -- never invokes pkill at all) and `env FOO=1 grep pkill f.log`
    (same shape, grep's search term) were both misread as invocations."""
    start = 0
    for k in range(i - 1, -1, -1):
        if tokens[k] in COMMAND_START_TOKENS:
            start = k + 1
            break
    span = tokens[start:i]
    seen_wrapper = False
    for idx, tok in enumerate(span):
        if os.path.basename(tok) in WRAPPER_PREFIXES or ASSIGNMENT_RE.match(tok):
            seen_wrapper = True
        elif not seen_wrapper:
            return False
        elif tok.startswith("-") or span[idx - 1].startswith("-"):
            pass  # the wrapper's own flag, or that flag's value
        else:
            return False
    return seen_wrapper


def _is_command_position(tokens, i):
    if i == 0 or tokens[i - 1] in COMMAND_START_TOKENS:
        return True
    return _wrapper_chain(tokens, i)


def find_invocation(tokens):
    """True if any pkill/killall token in `tokens` is in real command
    position. The single rule only needs a yes/no -- never which one, or
    what its arguments are -- so this short-circuits on the first hit."""
    for i, tok in enumerate(tokens):
        if os.path.basename(tok) in ("pkill", "killall") and _is_command_position(tokens, i):
            return True
    return False


DENY_REASON = (
    "pkill/killall is blocked for agent Bash calls, unconditionally -- no pattern, "
    "flag, or process-table analysis, just a flat deny. On 2026-07-28 18:30, a "
    "single pkill call with a misordered flag SIGTERM'd 8 claude sessions plus a "
    "production daemon (bead ga-jo3xl); a guard that then tried to allow "
    "'safe-looking' pkill/killall forms by analyzing patterns and flags was "
    "bypassed by 6 different subtleties across 6 review rounds (ga-tje7u) -- so no "
    "pkill/killall form is trusted as safe enough to allow anymore. Instead:\n"
    "  1. validate first, read-only:  pgrep -lf '<pattern>'\n"
    "  2. kill by PID:  kill <pid>   (or `kill $!` for your own nohup'd process)\n"
    "  3. never reuse a basename a production process/daemon also uses -- that's "
    "how the 2026-07-28 production daemon died too, alongside the 8 sessions."
)


def decide(command):
    if not CMD_RE.search(command):
        return "allow", None
    try:
        tokens = _tokenize(command)
    except Exception as exc:
        return "deny", (
            "This command mentions pkill/killall, but its shell syntax could not "
            "be parsed to verify what it would actually do (%s: %s) -- refusing "
            "rather than assuming an unparseable command is safe. Simplify the "
            "quoting, or validate by hand with the read-only `pgrep -lf <same "
            "args>` first. (See ga-jo3xl for why pkill/killall gets this "
            "scrutiny.)" % (type(exc).__name__, exc)
        )
    if find_invocation(tokens):
        return "deny", DENY_REASON
    return "allow", None


def emit(decision, reason):
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision}}
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

        # Selftest-only fault injection (AC5 proof): never set in production.
        if os.environ.get("PKILL_GUARD_SELFTEST_FORCE_ERROR") == "1":
            raise RuntimeError("selftest-forced error to prove the fail-open path")

        emit(*decide(command))
    except Exception:
        # Fail OPEN: a bug in THIS SCRIPT (malformed JSON payload, a coding
        # error) must never block an unrelated Bash call. decide()'s own
        # tokenizer failures are caught inside decide(), not here, and
        # turned into an explicit deny -- that's a verified "cannot check
        # this command" RESULT, not this script breaking.
        pass


if __name__ == "__main__":
    main()
