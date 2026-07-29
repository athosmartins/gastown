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

FIX-ATTEMPT 4 closed two more gaps a gate reviewer found in fix-attempt 3's
inversion -- one false positive, one more silent-allow of the same
error-vs-empty shape as before:
  - find_invocations() matched the "pkill"/"killall" basename ANYWHERE in
    the token stream with no regard for position, so the word used as a
    plain STRING ARGUMENT to an unrelated command (`man pkill`, `which
    pkill`, `echo pkill`, `type pkill`, `apropos killall` -- none of which
    actually run pkill/killall) was misread as a real, criteria-only
    invocation and denied. Fixed via _is_command_position: a pkill/killall
    token only counts as a real invocation now if it's the first token of
    its command, immediately after a separator, HAS trailing args/flags of
    its own (true regardless of what precedes it -- see the non-whitelist
    note in _is_command_position's own docstring for why this, not a
    wrapper-name whitelist, is what actually closes this safely), or is
    reached only through a recognized transparent wrapper/assignment
    prefix (`sudo`, `doas`, `nohup`, `env`, or a leading `VAR=value`).
  - UNVERIFIABLE_PATTERN_RE matched named variables ($VAR, ${VAR}),
    $(...), and backticks, but missed shell SPECIAL/POSITIONAL parameters
    ($1-$9, $@, $*, $#, $?, $!, $$, $0, $-) -- e.g. `pkill -f "$1"` or
    `pkill -f "myscript-$$"` were silently ALLOWED, the identical
    "checked-the-literal-text-not-what-it-expands-to" collapse fix-attempt
    2 closed for named variables, just left open for this other class of
    unexpanded reference. Fixed by widening the regex.

FIX-ATTEMPT (2026-07-29, post budget-fix): closed a further gap in the same
error-vs-empty family, this time a tokenizer/operand-classification bug
rather than a pattern-verification one. shlex's punctuation_chars mode
glues ANY run of adjacent characters from its fixed set "();<>|&" into one
token with no regard for shell semantics, which produced two distinct
bypasses, both confirmed live against the committed guard before this fix:
  - a redirection operator (`>`, `<`, `>>`, `<<`, `>&`, `&>`, `<&`, `<>`),
    including fd-dup forms that tokenize with a leading bare digit (e.g.
    `2>/dev/null` -> "2", ">", "/dev/null"), was read as an ordinary
    pattern/target operand. `pkill -U 501 2>/dev/null` and `pkill -U $(id
    -u) >/tmp/x` produced non-empty "operands" out of the stray
    "2"/">"/"/dev/null"/"/tmp/x" text, so rule (b)'s "no pattern operand"
    never fired -- whether the command was denied at all then depended on
    the unrelated accident of whether that punctuation/path text happened
    to also match a live process on the machine running the check. The
    real ga-jo3xl incident line itself contained "2>/dev/null" on both its
    pkill calls; every selftest through this fix, including AC6(i), had
    only ever exercised a sanitized version without it.
  - two distinct real shell operators glued with no separating whitespace
    (e.g. "&;" -- backgrounding immediately followed by a statement
    separator) merge into ONE token matching neither a known SEPARATOR nor
    a known redirect operator, so find_invocations's "stop at the next
    separator" cutoff never fires and everything after it -- not just
    redirection syntax -- is silently absorbed into the PRECEDING
    command's own argv instead of ending it there.
Fixed at the root: _split_operator_run re-tokenizes any pure-punctuation
run shlex hands back into the real operators it represents (longest match
first, e.g. "&&"/">>"/">&"/"&>" before the single-character forms), so
every later stage always sees canonical, individually-recognized tokens --
never a fused hybrid -- and split_operands_and_flags treats a recognized
redirect operator (never a statement separator, which is already handled)
as the end of the operand list, popping a bare fd-number token immediately
in front of it back off since it was never a real operand.

WHAT: reads a single Claude Code PreToolUse hook payload from stdin. When
tool_name is "Bash" and tool_input.command contains a pkill/killall
invocation in command position -- including one glued flush against a
preceding ;/&&/||/|/& with no whitespace, e.g. "echo hi;pkill ..." --
denies per the rules above. killall's documented multi-target form
(`killall firefox slack`) is treated as multiple legitimate targets, each
individually checked below -- NOT as a single pattern followed by a stray
flag (that was itself a false-positive a gate reviewer found: `killall
firefox slack` was denied as though "slack" were a misplaced flag).
  (a) the pattern/first target is not the last operand -- i.e. a flag
      appears after it -- the exact defect behind ga-jo3xl's incident,
      checked by pure argv inspection;
  (b) no pattern/target operand is present at all (criteria-only, e.g.
      `pkill -U 501`);
  (c) a pattern contains unexpanded shell variable/substitution syntax, or
      an unexpanded special/positional shell parameter ($1, $$, $@, ...);
  (d) a pattern currently matches any process whose command line contains
      "claude" (checked read-only via `pgrep -fl`);
  (e) a pattern currently matches more than N processes (default 5,
      override via PKILL_GUARD_MAX_MATCHES);
  (f) pgrep itself fails or times out while checking (d)/(e).
Every other command -- including plain `kill $PID`, and pkill/killall used
as a plain argument to an unrelated command like `man pkill` -- is allowed
untouched. Only pkill/killall invocations in command position are ever
inspected; the candidate command itself is never executed by this guard.

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
# Must stay comfortably under BOTH the <1s budget (AC4) AND the 5s timeout
# pkill-blast-guard-activate.sh registers for this hook -- a hook that
# exceeds ITS timeout does not fail closed (Claude Code treats a timed-out
# hook as though it never ran), so decide() must actually enforce this
# deadline everywhere it makes a pgrep call, not just once per invocation;
# see the per-operand deadline check in decide() for the gap this closed.
OVERALL_BUDGET_SECS = 0.9

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

# Command names that forward execution to the NEXT word rather than being
# the real target themselves -- `sudo pkill ...` and `nohup pkill ...` are
# just as dangerous as bare `pkill ...`, so a command-position check (see
# _is_command_position) must still recognize pkill/killall behind one of
# these. Deliberately narrow (not an exhaustive process-wrapper taxonomy):
# sudo/doas are privilege-elevation, nohup/env are the two forms already
# named in this module's own docstring plus the idiom this very selftest
# uses (`env VAR=val cmd`). Extend if a future review finds a concrete gap.
WRAPPER_PREFIXES = {"sudo", "doas", "nohup", "env"}

# A leading inline shell assignment (`FOO=bar pkill ...`) is the same
# "transparent prefix" shape as a wrapper command -- bash runs the real
# command with that variable scoped to it, so pkill/killall right after
# is just as real an invocation as if the assignment weren't there.
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

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


# shlex's punctuation_chars mode returns any RUN of adjacent characters from
# its fixed set "();<>|&" as a single token, with no regard for where one
# real shell operator ends and the next begins -- e.g. "&;" (backgrounding
# glued flush against a following separator) comes back as ONE token that
# doesn't equal any string in SEPARATORS. Longest-match-first vocabulary of
# every operator shlex's punctuation_chars can ever produce a run of; 2-char
# forms MUST precede their 1-char prefixes (e.g. "&&" before "&") so the
# greedy match in _split_operator_run below picks the real operator, not an
# arbitrary prefix of it.
_KNOWN_OPERATORS = (
    "&&", "||", ">>", "<<", ">&", "&>", "<&", "<>",
    ";", "&", "|", "<", ">", "(", ")",
)
_PUNCTUATION_RUN_RE = re.compile(r"^[();<>|&]+$")

# Redirection operators specifically -- as opposed to the statement
# separators in SEPARATORS, which end an INVOCATION -- are never a
# pkill/killall pattern/target operand; see split_operands_and_flags.
REDIRECT_OPERATORS = {">>", "<<", ">&", "&>", "<&", "<>", "<", ">"}


def _split_operator_run(tok):
    """If `tok` is composed entirely of shlex punctuation_chars, re-split it
    into the real shell operators it represents, longest match first (e.g.
    "&;" -> ["&", ";"], "&&" stays ["&&"], ">&" stays [">&"]). Without this,
    two DISTINCT operators glued with no whitespace between them (only
    possible when both are punctuation characters -- a digit or letter in
    between already breaks shlex's own run) come back as one token that
    downstream code (SEPARATORS / REDIRECT_OPERATORS membership checks) does
    not recognize as anything, silently absorbing whatever follows into the
    wrong invocation's argv. Returns [tok] unchanged for the overwhelmingly
    common case of an ordinary word/flag/pattern, which this never touches."""
    if not _PUNCTUATION_RUN_RE.match(tok):
        return [tok]
    out = []
    i, n = 0, len(tok)
    while i < n:
        for op in _KNOWN_OPERATORS:
            if tok.startswith(op, i):
                out.append(op)
                i += len(op)
                break
        else:
            # Unreachable while _KNOWN_OPERATORS covers every character in
            # _PUNCTUATION_RUN_RE's class as a 1-char operator on its own --
            # kept as a safe fallback rather than raising, consistent with
            # this function's job being pure re-tokenization, not detection.
            out.append(tok[i])
            i += 1
    return out


def _tokenize(command):
    """Tokenize like shlex.split, but also split shell control/redirection
    operators (;, &&, ||, |, &, >, <, >>, <<, >&, &>, <&, <>) into their own
    tokens even when glued flush against a neighboring word or against EACH
    OTHER with no whitespace (e.g. "echo hi;pkill ...", "pkill ... &;ls").
    Plain shlex.split only splits on whitespace, so a glued separator leaves
    the next command's name fused onto it as one token (e.g. "hi;pkill")
    that never matches the "pkill"/"killall" basename check in
    find_invocations -- silently hiding that entire invocation from the
    guard. Quoting still protects operator characters that are genuinely
    part of a pattern (e.g. 'foo;bar' stays one token); this only affects
    unquoted operators. $(...)/`...` spans are protected first (see
    _protect_command_substitutions) and restored per-token after shlex has
    decided token boundaries, so a command-substitution value survives as
    one token instead of being shattered by the same punctuation splitting;
    _split_operator_run then further divides any token that -- even after
    restoration -- is still composed entirely of punctuation characters,
    since shlex's own run-merging can fuse two distinct real operators
    together (see that function's docstring)."""
    protected, placeholders = _protect_command_substitutions(command)
    lexer = shlex.shlex(protected, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = []
    for tok in lexer:
        tokens.extend(_split_operator_run(_restore(tok, placeholders)))
    return tokens


def _simple_command_span(tokens, i):
    """Return the slice of `tokens` from the start of the current simple
    command (index 0, or just after the nearest preceding SEPARATOR) up to
    but not including index i. Used by _is_command_position to inspect
    everything between the start of a command and a pkill/killall candidate
    token."""
    start = 0
    for k in range(i - 1, -1, -1):
        if tokens[k] in SEPARATORS:
            start = k + 1
            break
    return tokens[start:i]


def _is_transparent_prefix_span(span):
    """True if every token in `span` (the tokens between the start of the
    current simple command and a pkill/killall candidate) is consistent
    with being part of a transparent wrapper chain: a WRAPPER_PREFIXES
    command name, an inline VAR=VALUE assignment, or -- once at least one
    of those has appeared -- that wrapper's own flags/flag-values (e.g.
    "-u root" after "sudo"). Deliberately permissive about what counts as
    a flag-value once a wrapper/assignment is seen: this guard does not
    model each wrapper's exact flag grammar, and erring toward STILL
    treating the following token as a real invocation (deny-unless-
    verified-safe) is the safe direction, not the reverse."""
    if not span:
        return False
    seen_transparent = False
    for tok in span:
        base = os.path.basename(tok)
        if base in WRAPPER_PREFIXES or ASSIGNMENT_RE.match(tok):
            seen_transparent = True
            continue
        if seen_transparent:
            continue
        return False
    return seen_transparent


def _is_command_position(tokens, i, args):
    """True if tokens[i] (a pkill/killall token whose already-collected
    trailing argv is `args`, cut off at the next separator) is a REAL
    invocation rather than the word "pkill"/"killall" merely appearing as a
    plain argument to some other command (e.g. `man pkill`, `echo pkill`).
    True whenever ANY of:
      - it's the very first token overall, or immediately after a
        SEPARATOR -- an unambiguous command start;
      - `args` is non-empty -- a pkill/killall token that goes on to take
        its OWN flags/operands is being invoked, REGARDLESS of what
        precedes it. This is deliberately NOT a wrapper whitelist: an
        earlier version of this fix used one (WRAPPER_PREFIXES below) and,
        checked live, silently ALLOWED `exec pkill -U 501`, `time pkill -U
        501`, `command pkill -U 501`, `! pkill -U 501`, and `... | xargs
        pkill -U 501` -- none of these wrapper/builtin names happened to be
        enumerated, so the whitelist-only check classified all five as
        "not command position" and let a criteria-only pkill straight
        through unexamined. Requiring non-empty trailing args instead
        closes that whole class without having to enumerate every
        possible prefix: whatever precedes pkill/killall, if it goes on to
        take its own arguments, it is being invoked;
      - reached only through a recognized transparent wrapper/assignment
        prefix (see _is_transparent_prefix_span) -- this covers the
        remaining bare, ZERO-argument edge case (`sudo pkill` / `nohup
        pkill` with nothing else), which the non-empty-args rule alone
        would misclassify as inert. Real BSD pkill/killall with literally
        no operands AND no criteria flags errors out immediately (usage
        message) regardless of wrapper, so this case is never actually
        dangerous either way -- this clause exists only to keep the
        module docstring's explicit "catches sudo pkill, nohup pkill"
        promise true to the letter, not because it closes a live risk.
    A plain word followed by a bare pkill/killall with NO args of its own
    (man pkill, which pkill, echo pkill, type pkill, apropos killall) hits
    none of these and is correctly read as an argument, not an invocation."""
    if i == 0 or tokens[i - 1] in SEPARATORS:
        return True
    if args:
        return True
    return _is_transparent_prefix_span(_simple_command_span(tokens, i))


def find_invocations(command):
    """Yield the argv list following each pkill/killall command-word
    occurrence in `command` that is actually in command position (see
    _is_command_position) -- not merely a plain string argument to some
    other command (e.g. `man pkill`, `echo pkill`). Each yielded argv list
    is cut off at the next shell separator token (;, &&, ||, |, &) or end
    of string. Raises on unparseable input (unbalanced quotes/parens/
    backticks) -- caller treats that as a verification failure on a
    command already confirmed (by the caller's coarse pre-filter) to
    mention pkill/killall, i.e. it denies rather than assuming unparseable
    means safe."""
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
            if _is_command_position(tokens, i, args):
                yield args
                i = j
                continue
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
    as an operand itself, e.g. `-U 501` contributes zero operands).

    A REDIRECT_OPERATORS token (>, <, >>, <<, >&, &>, <&, <>) is never a
    pkill/killall operand -- shell redirection, wherever it appears in a
    simple command, is stripped by the shell before argv ever reaches the
    invoked program. Per gate review (the ga-jo3xl 2026-07-29 GATE-FEEDBACK),
    this is the exact reason `pkill -U 501 2>/dev/null` and `pkill -U $(id
    -u) >/tmp/x` were both previously misread as HAVING an operand (the
    stray "2"/">"/"/dev/null"/"/tmp/x" text) when they actually supply none
    -- silently skipping rule (b) for the identical criteria-only blast
    radius as ga-jo3xl's original misordered-flag incident. On hitting a
    redirect operator this stops collecting entirely (conservative: real
    commands never need a "real" operand to follow a redirect in practice,
    and treating everything from here on as non-operand can only make this
    guard MORE likely to deny, never less). A bare fd-number token
    immediately in front of the operator (e.g. "2" in "2>/dev/null") was
    already appended as an operand one iteration earlier -- shlex can never
    glue a digit to adjacent punctuation, so it always arrives as its own
    token -- and is popped back off now that the redirect confirms it was
    an fd prefix, not a real operand."""
    operands = []
    flag_after_operand = False
    i, n = 0, len(args)
    while i < n:
        tok = args[i]
        if tok in REDIRECT_OPERATORS:
            if (
                operands
                and i > 0
                and args[i - 1] == operands[-1]
                and re.match(r"^\d+$", operands[-1])
            ):
                operands.pop()
            break
        if tok.startswith("-") and tok != "-":
            if operands:
                flag_after_operand = True
            i += 2 if tok in ARG_TAKING_FLAGS else 1
            continue
        operands.append(tok)
        i += 1
    return operands, flag_after_operand


UNVERIFIABLE_PATTERN_RE = re.compile(r"\$\{|\$\(|\$[A-Za-z_0-9@*#?!$-]|`")


def pattern_unverifiable(pattern):
    """True if `pattern` contains unexpanded shell variable/substitution
    syntax: a named variable ($VAR, ${VAR}), $(...) or backtick command
    substitution, or a special/positional parameter ($0-$9, $@, $*, $#, $?,
    $!, $$, $-). pgrep would match this LITERALLY against the current
    process table -- e.g. checking the literal text "$TARGET" or "$$"
    finds ~zero matches on any real machine, which looks like "confirmed
    safe" but says nothing about what killing "$TARGET" (or the invoking
    shell's own PID, for "$$") will actually match once the shell expands
    it at runtime. Collapsing that unknown into a confirmed-safe read is
    the same error-vs-empty bug class as the pgrep_matches None/[]
    distinction below -- this function exists so decide() can tell the two
    apart too."""
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


def _budget_exceeded_reason():
    # Shared by both the per-invocation and per-operand deadline checks in
    # decide() -- see the comment at the per-operand check site for why a
    # single deadline needs to gate both loops, not just the outer one.
    return (
        "pkill/killall: this command has multiple invocations or targets "
        "to verify and ran out of the guard's analysis time budget before "
        "finishing -- refusing rather than allowing the unchecked "
        "remainder through. Split this into separate commands, or "
        "validate manually with `pgrep -lf`."
    )


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
            return "deny", _budget_exceeded_reason()

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
            # Gate-review finding (post-fix-attempt-4): this deadline check
            # was previously only at the top of the OUTER loop above, once
            # per pkill/killall invocation -- but a single invocation can
            # carry many operands (killall's documented `killall [procname
            # ...]` form), and each one costs a real pgrep subprocess via
            # check_pattern(). Measured live: ~17.6ms/operand, so a killall
            # with ~300+ plain space-separated targets -- not a contrived
            # shape, a plausible bulk-cleanup command -- blew past both
            # OVERALL_BUDGET_SECS and the 5s timeout
            # pkill-blast-guard-activate.sh registers for this hook. A
            # PreToolUse hook that exceeds its own registered timeout does
            # NOT fail closed (Claude Code treats a timed-out hook as if it
            # never ran, so the tool call proceeds unguarded) -- silently
            # defeating the entire guard, including the "matches a claude
            # process" check that is this fix's whole purpose. Checking the
            # deadline here too, before every individual pgrep call rather
            # than only before every invocation, caps the guard's own
            # worst-case wall time regardless of operand count.
            if time.monotonic() > deadline:
                return "deny", _budget_exceeded_reason()

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
