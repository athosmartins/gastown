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
anything -- it was a genuine mistake). This guard's own first gate review
(ga-tje7u gate FAIL + Mayor sweep, 2026-07-29) reinforced this: every one
of the holes found -- a comment above the real command, `if`/`while`/
`for`/`case` block keywords, `$(...)` hiding a `;`-joined command -- is
ordinary shell an agent writes with zero intent to evade anything. This
guard still makes no attempt to resist DELIBERATE evasion -- `pgrep |
xargs kill` walks straight past it, same as an `eval`/`bash -c` string
argument -- and that remains an accepted, documented gap, not an
oversight.

SCOPE: intercepts only the Bash tool calls of Claude Code AGENTS running
under this hook. Daemons, launchd jobs, and .sh scripts invoked outside an
agent's Bash tool never pass through this hook -- e.g.
adb_usb_recover.sh's own `pkill -9 -f 'adb.*fork-server'` is unaffected.

COMMAND POSITION: pkill/killall counts as a real invocation -- not a plain
argument to some other command (`man pkill`, `echo pkill`) -- when EITHER:
  (a) it's the first word of a simple command: start of the whole string,
      or immediately after a separator (; && || | &), an opening `(` or
      `{`, a closing `)` (a case-statement pattern like `a) pkill ..;;`
      opens its command list on `)` exactly like `{`/`(` open one --
      ga-tje7u Mayor sweep, 2026-07-29), one of the block keywords that
      always introduces a new command list (then, do, else, elif), or a
      newline (converted to `;` before tokenizing -- see COMMENTS below
      for why that conversion must happen AFTER comment-stripping, not
      before);
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

Deliberately NOT extended to `if`/`while`/`until`/`for`/`case` themselves,
only to the keywords that follow their condition/list (then, do, else,
elif) plus the case-pattern `)`: a real pkill/killall call in ordinary
agent-written shell sits directly after THOSE, not after `if`/`while`
itself. `for` in particular is always followed by a variable name, never
a command, so adding it would add surface for zero benefit.

COMMENTS (`#`): a `#` at the start of a word (start of string, or right
after whitespace/a separator/an opening paren-or-brace) starts a comment
that runs to the end of its OWN physical line -- exactly like real bash,
and unlike a `#` embedded mid-word (`http://x/#y`) or inside quotes
(`"a#b"`), both of which stay literal. This has to be resolved BEFORE the
newline-to-";" conversion below, not by shlex's own built-in comment
handling: shlex's comment-skip reads to the next raw "\n" in the
INSTREAM it's given, but this guard already replaces every real "\n"
with ";" so the tokenizer can see statement boundaries -- so by the time
shlex ran its own comment logic, there was no "\n" left to stop at, and a
`#` silently swallowed EVERYTHING after it, including a real pkill call
on the next line (ga-tje7u gate FAIL, 2026-07-29: `# note\npkill -f x`
tokenized to nothing and allowed). Fix: strip comments ourselves first,
character by character with quote-tracking, leaving the terminating
newline in place for the ";" conversion to see -- then disable shlex's
own `commenters` so it never independently re-applies a second, possibly
divergent comment pass on top of ours.

Both gate FAILs on this file were the same shape -- TWO passes with
DIFFERENT ideas of which text is live, over one string. Attempt 1: shlex's
comment pass vs the newline-to-";" conversion. Attempt 2: substitution-
protection (raw substring scan, quote-blind) vs comment-stripping
(carefully quote-aware) -- see COMMAND SUBSTITUTION. So comment-stripping
and substitution-protection are now ONE traversal sharing ONE quote and
word-start state (_protect_and_strip), which is why neither can disagree
with the other again. Add a third opinion about what is live only with
that history in mind.

COMMAND SUBSTITUTION (`$(...)`, `` `...` ``): the shell always executes a
substitution's content for its side effects, no matter what the outer
command does with the captured stdout -- `echo $(pkill -f x)` really
invokes pkill even though nothing ever prints it. This guard protects
each balanced `$(...)`/backtick span with an opaque placeholder before
tokenizing the OUTER command (so e.g. a wrapper's "-U $(id -u)" flag
value survives as one token instead of being shattered by the inner
parens), then separately re-applies this SAME rule -- recursively -- to
each span's own captured inner text.

Only spans bash would actually EXECUTE are captured: unquoted, or inside
DOUBLE quotes (which expand them). A span inside SINGLE quotes is inert
text and one inside a comment is never parsed at all, so neither is
captured, and find_invocation() therefore can't recurse into something
unreachable and deny on it. Capturing them is exactly what made `echo hi
# $(pkill -f a)` and `echo '$(pkill -f a)'` deny commands that run no
pkill (ga-tje7u gate FAIL attempt 2/3, 2026-07-29). The contrast is
load-bearing in both directions and pinned as paired tests: `echo
"$(pkill -f a)"` still denies, and neither inert form can be used to hide
a real call that follows it. A bare pkill wrapped as the ENTIRE
command (`$(pkill -9 -f pattern)`) and a pkill hidden as one statement in
a `;`-joined list inside a substitution used for something else (`echo
$(echo a; pkill -f a)`) are the same threat by this logic and both deny
now (ga-tje7u Mayor sweep, 2026-07-29 -- the first submission treated
only the latter shape as a gap and the former as equivalent to the
accepted `bash -c` gap below; empirically they're identical, so both are
covered). Still NOT covered, deliberately: a pkill hidden in a string
handed to `eval` or `bash -c`/`sh -c` -- those re-interpret a plain
argument STRING as new shell text via their OWN semantics, which no
amount of shell-syntax scanning reveals; catching that means knowing what
`eval`/`bash -c` specifically DO with their argument, which is exactly
the kind of per-command special-casing this design tries to avoid.
`eval "pkill -f a"` and backslash-mangled forms designed purely to dodge
literal text-matching (of which `eval` is the flagship example) remain
open (ga-tje7u Mayor sweep, 2026-07-29: flagged as "fix if it's free,
don't build machinery to chase it" -- eval wasn't free, so it's still
open; the backslash-in-the-token-itself case, `pk\\ill -f a`, WAS free --
see find_invocation's docstring -- and is fixed).

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
# Keywords after which the NEXT word is a genuine command.
#   then/do/else/elif -> the command sits in the BODY of the block.
#   if/while/until    -> the command IS the block's CONDITION (gate FAIL 4/4).
# An earlier revision listed only the body keywords, reasoning that "a real
# pkill call sits directly after then/do, not after if/while itself". That is
# factually wrong for the condition slot: in `if pkill -f a; then ...; fi` the
# pkill IS the condition expression, executed exactly like any other command.
# With "if" in neither this set nor WRAPPER_PREFIXES, _is_command_position()
# fell through to _wrapper_chain(), which returned False on the first span
# token -- so the call was ALLOWED. That is a FALSE NEGATIVE, the catastrophic
# direction for this guard, and it needs ZERO obfuscation to hit: `if pkill -f
# x; then` and `while pkill -f x; do` are the ordinary "kill if running" /
# "kill in a loop" idioms this guard's own docstring puts in scope.
BLOCK_KEYWORDS = ("then", "do", "else", "elif", "if", "while", "until")
COMMAND_START_TOKENS = SEPARATORS + ("(", ")", "{") + BLOCK_KEYWORDS
WRAPPER_PREFIXES = {"sudo", "doas", "nohup", "env", "time", "xargs", "exec", "command", "!"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# A '#' only starts a comment when it's the first character of a NEW word --
# i.e. right after one of these, or at the very start of the command.
_WORD_BREAK_CHARS = frozenset(" \t\n;&|(){}")

# Opaque, NUL-delimited placeholder for a protected $(...)/`...` span -- NUL
# can't appear in a real shell command string, so this can never collide.
_CMDSUB_PLACEHOLDER = "\x00CMDSUB%d\x00"
_CMDSUB_PLACEHOLDER_RE = re.compile(r"\x00CMDSUB\d+\x00")

# Every operator shlex's punctuation_chars="();<>|&" mode can hand back as
# one fused token. Longest match first so e.g. "&&" isn't split into "&","&".
_KNOWN_OPERATORS = (
    "<<<", "&>>", "&&", "||", ">>", "<<", ">&", "&>", "<&", "<>",
    ";", "&", "|", "<", ">", "(", ")",
)
_PUNCTUATION_RUN_RE = re.compile(r"^[();<>|&]+$")


def _scan_cmdsub_end(command, start):
    """Index just past the `)` that closes a `$(` opened before `start`, or
    None if it never closes.

    Parens are counted ONLY outside quotes. A `)` inside a quoted string is
    literal text to the shell, not a closer -- `$(grep -c ")" f.txt)` is one
    complete substitution, not one that ends at the quoted paren.

    Counting parens raw, without this quote state, was the gate FAIL 3/3
    (2026-07-31): the span closed early at the quoted `)`, the leftover `"`
    leaked into the OUTER scan and desynced ITS quote state, shlex then threw
    "No closing quotation", and decide()'s parse-failure path -- which cannot
    tell "genuinely unparseable command" from "my own scanner desynced" --
    fell back to a raw text search and DENIED commands that invoke no
    pkill/killall at all (any command that merely mentions the word while
    containing this ordinary paren-in-a-string idiom). One-directional: false
    DENY, never false ALLOW. The irony worth remembering: the docstring above
    claims one traversal with one shared quote state precisely so nothing can
    disagree -- and this scanner, nested inside it, was keeping its own
    quote-blind opinion.
    """
    depth, i, n = 1, start, len(command)
    quote = None  # None, "'", or '"'
    while i < n:
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:  # escape (inert in single quotes, handled above)
            i += 2
            continue
        if quote == '"':
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _scan_backtick_end(command, start):
    """Index of the backtick closing one opened before `start`, or None.

    Same quote-awareness as _scan_cmdsub_end, for the same reason: a backtick
    inside a quoted string is literal. Flagged by the same gate review as a
    secondary instance of the identical root cause (`command.find` was equally
    quote-blind), so it is fixed the same way rather than left to resurface.
    """
    i, n = start, len(command)
    quote = None
    while i < n:
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if quote == '"':
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        if ch == "`":
            return i
        i += 1
    return None


def _protect_and_strip(command):
    """ONE left-to-right pass doing BOTH jobs the tokenizer needs done
    before shlex sees the text, off a SINGLE shared quote/word-start state:

      * delete bash comments -- an unquoted `#` at the start of a word,
        through the end of its own physical line -- leaving the
        terminating newline in place for the caller's newline-to-";"
        conversion to see. A `#` inside quotes (`"a#b"`) or glued mid-word
        (`http://x/#y`) stays literal, exactly like real bash;
      * replace each LIVE balanced `$(...)`/backtick span with an opaque
        placeholder, so a wrapper's "-U $(id -u)" flag value survives as
        ONE token instead of being shattered -- a stray "(" from a
        shattered substitution would otherwise read as a command-start
        token. The captured raw text is what find_invocation() recurses
        into.

    LIVE is the whole point, and the reason this is one pass instead of
    two. A substitution inside SINGLE quotes is inert text (bash performs
    no expansion there) and one inside a comment is never parsed at all;
    capturing either put an unreachable span into `placeholders`, which
    find_invocation() then recursed into and denied on. That is what made
    `echo hi # $(pkill -f a)` and `echo '$(pkill -f a)'` deny (ga-tje7u
    gate FAIL attempt 2/3, 2026-07-29) even though bash runs no pkill in
    either. Inside DOUBLE quotes a substitution IS live -- bash expands it
    -- so it is still captured, and `echo "$(pkill -f a)"` still denies.

    Splitting this across two passes is what made that bug possible:
    substitution-protection ran first over the RAW string with no
    quote/comment awareness, while comment-stripping, forty lines away,
    tracked quotes carefully -- one string, two disagreeing opinions about
    which spans are live, and the careless one ran first. Both gate FAILs
    on this file were that same shape (attempt 1: shlex's comment pass
    disagreeing with the newline conversion). Merging them makes the
    disagreement UNREPRESENTABLE rather than merely fixed: there is now a
    single traversal and a single answer to "is this text live?".

    Raises ValueError on an unbalanced span; decide() turns a parse
    failure into an explicit deny, never a fail-open allow."""
    out, placeholders = [], {}
    quote = None  # None, "'", or '"'
    at_word_start = True
    i, n, counter = 0, len(command), 0
    while i < n:
        ch = command[i]

        # Single quotes suppress EVERYTHING: no substitution, no comment.
        if quote == "'":
            out.append(ch)
            if ch == "'":
                quote = None
            i += 1
            continue

        # Live substitution: unquoted, or inside double quotes (which do
        # expand it). Checked before the double-quote passthrough below so
        # the span is captured rather than copied through verbatim; a
        # backslash-escaped `\$(` never reaches here, because the escape
        # branches consume both characters first.
        if ch == "$" and i + 1 < n and command[i + 1] == "(":
            j = _scan_cmdsub_end(command, i + 2)
            if j is None:
                raise ValueError("unbalanced $(...) in command")
            key = _CMDSUB_PLACEHOLDER % counter
            placeholders[key] = command[i:j]
            out.append(key)
            counter += 1
            i = j
            at_word_start = False
            continue
        if ch == "`":
            j = _scan_backtick_end(command, i + 1)
            if j is None:
                raise ValueError("unbalanced ` in command")
            key = _CMDSUB_PLACEHOLDER % counter
            placeholders[key] = command[i:j + 1]
            out.append(key)
            counter += 1
            i = j + 1
            at_word_start = False
            continue

        if quote == '"':
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(command[i + 1])
                i += 2
                continue
            if ch == '"':
                quote = None
            i += 1
            continue

        if ch == "\\" and i + 1 < n:
            out.append(ch)
            out.append(command[i + 1])
            i += 2
            at_word_start = False
            continue

        if ch in ("'", '"'):
            out.append(ch)
            quote = ch
            at_word_start = False
            i += 1
            continue

        if ch == "#" and at_word_start:
            while i < n and command[i] != "\n":
                i += 1
            continue

        at_word_start = ch in _WORD_BREAK_CHARS
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
    word (e.g. "echo hi;pkill ..."). Returns (tokens, placeholders) --
    the placeholders map lets find_invocation() recurse into each
    protected $(...)/`...` span's own captured text. An unquoted newline
    is a statement separator in real bash exactly like ";" -- shlex
    treats it as plain whitespace and drops it, so it's converted to ";"
    (AFTER comment-stripping, which needs the real newline as the
    comment terminator -- see COMMENTS in the module docstring) to keep
    that separator meaning visible. Quoting still protects any operator
    character that's genuinely part of a pattern (e.g. 'foo;bar' stays
    one token)."""
    protected, placeholders = _protect_and_strip(command.replace("\r\n", "\n"))
    protected = protected.replace("\n", ";")
    lexer = shlex.shlex(protected, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""  # comments already stripped above -- see COMMENTS in module docstring
    tokens = []
    for tok in lexer:
        tokens.extend(_split_operator_run(_restore(tok, placeholders)))
    return tokens, placeholders


# Precisa casar EXATAMENTE o conjunto que `_KNOWN_OPERATORS` sabe fundir num token só.
# Um operador que o tokenizador entrega inteiro mas que NÃO esteja aqui vira uma "palavra"
# qualquer no span, `_drop_redirects` não o remove, e o `pkill` depois dele deixa de ser
# lido como primeira palavra -> ALLOW. Foi exatamente o que aconteceu com `<<<` e `&>>`
# (01/08): acrescentá-los só ao `_KNOWN_OPERATORS` fundiu os tokens e ABRIU dois bypasses
# (`<<<x pkill -f y`, `&>>/tmp/o pkill -f x`) — os dois bash válido, os dois falso-NEGATIVO.
# Ao mexer num dos dois conjuntos, mexa no outro: eles são um pacto, não duas listas.
_REDIR_OPS = ("<<<", "&>>", ">>", "<<", ">&", "&>", "<&", "<>", ">", "<")


def _drop_redirects(span):
    """Remove os REDIRECTS de um span de tokens — eles nao dizem NADA sobre posicao de comando.

    Em bash, redirect pode vir ANTES do comando: `2>/dev/null pkill -f x` invoca pkill
    exatamente como `pkill -f x 2>/dev/null`. Sintaxe valida (bash -n) e idioma comum.

    Isto foi o gate FAIL 5/5 (01/08). O guard negava a forma com redirect no FIM e LIBERAVA
    a mesma linha com o redirect no COMECO — inclusive a linha verbatim do incidente de
    28/07 do proprio selftest (AC11), so com o `2>/dev/null` movido pra frente. Sem nenhuma
    ofuscacao: falso-NEGATIVO, a direcao catastrofica.

    RAIZ: `_wrapper_chain` olhava pra tras e via os tokens ['2','>','/dev/null']. O alvo
    (`/dev/null`) nao e wrapper nem `VAR=`, `seen_wrapper` ainda era False -> retornava
    "nao e cadeia de wrapper" -> nao e posicao de comando -> allow.
    A docstring de REDIRECTS afirmava "nenhum tratamento dedicado e necessario", mas o
    argumento que a sustentava so cobria redirect no FIM (que de fato nao importa, porque a
    posicao de comando so olha pra TRAS). Redirect ANTES estava fora do argumento inteiro.

    Consertar a CLASSE em vez do caso: o redirect (com fd opcional colado, `2>`) e o alvo
    dele viram transparentes ao olhar pra tras — em qualquer posicao, quantos quiserem. Isso
    tambem cobre `>out 2>&1 pkill`, `sudo 2>/dev/null pkill` e formas de fd-dup, que nunca
    foram testadas.
    """
    out, k, n = [], 0, len(span)
    while k < n:
        tok = span[k]
        # fd numerico colado no operador: ['2','>'] — o '2' sozinho nao e palavra de comando
        if tok.isdigit() and k + 1 < n and span[k + 1] in _REDIR_OPS:
            k += 2                      # pula fd + operador
            if k < n and span[k] not in _REDIR_OPS:
                k += 1                  # pula o ALVO do redirect
            continue
        if tok in _REDIR_OPS:
            k += 1
            if k < n and span[k] not in _REDIR_OPS:
                k += 1                  # pula o ALVO
            continue
        out.append(tok)
        k += 1
    return out


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
    span = _drop_redirects(tokens[start:i])
    # Span VAZIO depois de remover redirects => nao havia NADA de verdade entre o inicio do
    # comando simples e o pkill: ele E a primeira palavra. `2>/dev/null pkill -f x` cai
    # exatamente aqui. Sem esta linha o laco abaixo nem roda e a funcao devolve
    # `seen_wrapper=False` -> "nao e posicao de comando" -> ALLOW, que era metade do
    # gate FAIL 5/5 (a outra metade, com `sudo` no meio, ja passava pela cadeia de wrapper).
    if not span:
        return True
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


def find_invocation(command):
    """True if `command` contains a pkill/killall token in real command
    position, anywhere -- including inside a $(...)/`...` command
    substitution's own captured text, checked recursively (see COMMAND
    SUBSTITUTION in the module docstring). Operates on the raw command
    STRING rather than pre-split tokens so that a token-level obfuscation
    like `pk\\ill -f a` (an unquoted backslash-escape that shlex still
    joins into the single token "pkill", but which a raw substring check
    for the literal text "pkill" would miss) is only ever inspected after
    tokenization, never before it. The single rule only needs a yes/no --
    never which one, or what its arguments are -- so the top-level scan
    short-circuits on the first hit."""
    tokens, placeholders = _tokenize(command)
    for i, tok in enumerate(tokens):
        if os.path.basename(tok) in ("pkill", "killall") and _is_command_position(tokens, i):
            return True
    for raw in placeholders.values():
        inner = raw[2:-1] if raw.startswith("$(") else raw[1:-1]
        if find_invocation(inner):
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
    try:
        invoked = find_invocation(command)
    except Exception as exc:
        if CMD_RE.search(command):
            return "deny", (
                "This command mentions pkill/killall, but its shell syntax could not "
                "be parsed to verify what it would actually do (%s: %s) -- refusing "
                "rather than assuming an unparseable command is safe. Simplify the "
                "quoting, or validate by hand with the read-only `pgrep -lf <same "
                "args>` first. (See ga-jo3xl for why pkill/killall gets this "
                "scrutiny.)" % (type(exc).__name__, exc)
            )
        return "allow", None
    if invoked:
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
