#!/usr/bin/env python3
"""cut_output_egress.py (ga-d0hm85, slice 1/4) -- the egress guard of the cut-large-output SHADOW front.

## Contents
  What it is · Why it exists · Limits · CLI

WHAT IT IS. Pure functions that decide whether a piece of command output (or a command line) LOOKS like a credential or
personal data, so that it is neither sent to a third party (the Jev tier, built in the later slices of ga-d0hm85) nor left at
rest in the shared jev-experiment.jsonl. egress_withhold_reason() answers "secret" | "pii" | None for one block of text; sensitive_spans()
finds MULTI-LINE secrets over the WHOLE output (a PEM key BEGIN..END, a truncated one, a `kind: Secret` manifest) so a key
split across two blocks cannot look harmless in each half; ends_on_secret_key() says a block ends on a bare `password:` whose
value starts the next one (both are for the Jev planner of the later slices -- in this slice only the selftest calls them);
loggable_command() is the command as it may be logged or sent, and the only function of this module the shadow engine calls today.

WHY IT EXISTS. Phase 1 logged `command[:300]` raw, so a token typed into a command line sat in a log several daily reports read.
The Jev tier would also put block text in front of Cloudflare Workers AI -- outward-facing and not undoable. Two automated
security reviews of that tier found bypasses (a quote between name and separator, a DSN, a key split across blocks, a secret
after a long benign prefix, a cap that failed OPEN); every one is a test below.

LIMITS. A best-effort filter, not a proof: a name or a street address in plain prose is not detected, and an unusual secret
format passes. None means "none of the known shapes matched", NOT "safe". Every bound fails toward WITHHOLDING (more '@' signs, more
long runs, more markers than the scan will inspect, a command word that runs past the judged window -> do not send). Every
pattern is linear on hostile input.

CLI:
  python3 cut_output_egress.py selftest     pure, no network, no files
"""
from __future__ import annotations

import re
import sys
import time

COMMAND_LOG_CHARS = 300  # the command we log (and send) is a fingerprint, not a full replay
# The command is JUDGED over this many characters but LOGGED over COMMAND_LOG_CHARS: a credential that starts inside the logged
# prefix and ends after it must be seen whole (the gate caught loggable_command judging the already-cut prefix -- ga-d0hm85.1).
COMMAND_JUDGE_CHARS = 4096
COMMAND_WITHHELD = "[command withheld: it looks like it carries a credential or personal data]"


# ---------------------------------------------------------------------------------------------------------------
# Egress guard: text that looks like a credential or personal data is never sent.
# Every pattern is linear on hostile input (no unbounded run in front of an anchor): blocks are up to MAX_STATE_CHARS.
# ---------------------------------------------------------------------------------------------------------------
_KEY_WORDS = r"(?:password|passwd|secret|token|api[_-]?key|apikey|private[_-]?key|credential|access[_-]?key)"
_SECRET_RES = (
    re.compile(r"-----BEGIN [A-Z0-9 ]{0,40}-----"),  # any PEM block: private key, certificate, PGP...
    re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"(?i)\b(?:authorization|bearer)\b['\"]?[:\s]+[A-Za-z0-9._~+/=-]{12,}"),
    # name = value, name: value, "name": "value", 'name': 'value', X-Api-Key: value -- the optional quote after the name
    # is what a JSON / dict-repr dump has and a plain `name=value` pattern misses
    re.compile(r"(?i)" + _KEY_WORDS + r"\w*['\"]?\s*[=:]\s*['\"]?[^\s'\"]{6,}"),
    re.compile(r"(?i)\b(?:set-)?cookie\b['\"]?\s*[:=]\s*\S{8,}"),
    # scheme://user:password@host -- a DSN / URL with credentials (bounded runs, linear)
    re.compile(r"\b[a-z][a-z0-9+.-]{1,20}://[^\s/:@]{1,64}:[^\s/@]{3,}@"),
    # command-line shapes the `name=value` rule above cannot see (gate review of ga-d0hm85.1, medium finding). All are linear;
    # the flags that only mean something after a command word (curl -u, docker login -p, mysql -p) are _COMMAND_FLAG_RULES below.
    # `--password VALUE` / `--token VALUE` with a SPACE; `--token-file x` and `--password-stdin` have a '-' right after the name
    re.compile(r"(?i)(?<![\w-])--(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)\s+[^\s-]\S{5,}"),
    # `Authorization: <scheme> <value>` for any scheme word (Basic, Token, Digest...); the Bearer rule above wants the value first
    re.compile(r"(?i)\bauthorization\b['\"]?\s*[:=]\s*[A-Za-z][A-Za-z0-9_-]{0,20}\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"hooks\.slack\.com/services/[A-Za-z0-9]{6,}/[A-Za-z0-9]{6,}/[A-Za-z0-9]{8,}"),  # a Slack webhook URL is the credential
)
# A flag that is a credential only because of the command it belongs to: (command word, flag). The flag is looked for ANYWHERE after
# the FIRST command word in the text. Two earlier cuts were wrong: a bounded gap between the two (a lazy {0,200}) let `curl <a few
# headers> -u user:pass` through once the flag sat 200+ characters in, still inside the logged prefix; and splitting the text at
# newline, '|', ';' and '&' broke on a separator INSIDE quotes (`-H 'Content-Type: a; charset=utf-8' -u user:pass`) and on a
# backslash-continued multi-line curl -- both need a shell parser to get right (security reviews of the gate-fix commits). So there is
# no gap bound and no segmentation: a flag far from its word, or past some separator, is withheld too. That can withhold a command
# that did not carry a credential, which costs one fingerprint; a miss leaks one. Linear: one search for the word and one for the flag.
_COMMAND_FLAG_RULES = (
    # curl -u user:pass, -uuser:pass (attached), --user user:pass; `--user-agent` / `--upload-file` have a '-' after the name and are not it
    (re.compile(r"(?i)\bcurl\b"), re.compile(r"(?i)\s(?:-u\s*|--user(?:\s+|=))[^\s:]{1,64}:\S{3,}")),
    # docker login -p PASS, -pPASS (attached), --password PASS / --password=PASS; `--password-stdin` has a '-' after the name
    (re.compile(r"(?i)\b(?:docker|podman|nerdctl)\s+login\b"), re.compile(r"(?i)\s(?:-p\s*|--password(?:\s+|=))\S{3,}")),
    # mysql -pPASS (no space: with a bare `-p` mysql prompts). `-P` is the PORT, so only the command word is case-insensitive.
    (re.compile(r"(?i:\bmysql(?:dump|admin|pump)?)\b"), re.compile(r"\s-p\S{3,}")),
)
# A secret that ENDS a block ("password:" and the value on the next line, which is the next block): the block that follows
# is withheld too.
_ENDS_WITH_KEY_RE = re.compile(r"(?i)" + _KEY_WORDS + r"\w*['\"]?\s*[=:]\s*\Z")
_PEM_BEGIN_RE = re.compile(r"-----BEGIN [A-Z0-9 ]{0,40}-----")
_PEM_END_RE = re.compile(r"-----END [A-Z0-9 ]{0,40}-----")
_K8S_SECRET_RE = re.compile(r"(?im)^[ \t]*kind:[ \t]*Secret[ \t]*$")
_MAX_SPAN_MARKERS = 50  # a text with more begin-markers than this is a dump of keys: the whole output is one span
_PII_RES = (
    re.compile(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b"),  # CPF
    re.compile(r"\b\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}\b"),  # CNPJ
    re.compile(r"\+55[\s.-]?\(?\d{2}\)?[\s.-]?9?\d{4}[\s.-]?\d{4}"),  # +55 (31) 99999-8888
    re.compile(r"\(\d{2}\)\s?9?\d{4}[-\s]?\d{4}"),  # (31) 99999-8888
    re.compile(r"\b\d{2}\s9\d{4}[-\s]\d{4}\b"),  # 31 99999-8888
    re.compile(r"\b55\d{2}9?\d{8}\b"),  # 5531999998888 (a WhatsApp number)
    re.compile(r"@(?:s\.whatsapp\.net|c\.us|g\.us)\b"),  # a WhatsApp jid
)
# A run of token characters this long that mixes upper case, lower case and a digit ANYWHERE in it looks like a generated secret
# (a secret can follow a long benign prefix inside the same run, so the whole run is inspected, not a window). Hex-only strings
# (git shas, sha256) have no upper+lower mix and pass. Linear: finditer walks the text once, runs are disjoint, and each is
# scanned once (a lookahead-per-position regex was quadratic on a hostile 100k run).
_TOKEN_RUN_RE = re.compile(r"[A-Za-z0-9_-]{32,}")
_TOKEN_MAX_RUNS = 2000  # more long runs than this is a dump of identifiers/hashes: too many to inspect, so DO NOT SEND it


def _has_token_like_run(text: str) -> bool:
    for n, m in enumerate(_TOKEN_RUN_RE.finditer(text)):
        if n >= _TOKEN_MAX_RUNS:
            return True  # cannot inspect them all: the inert answer is "withhold", never "probably fine"
        upper = lower = digit = False
        for c in m.group(0):
            if c.isupper():
                upper = True
            elif c.islower():
                lower = True
            elif c.isdigit():
                digit = True
            if upper and lower and digit:
                return True
    return False


_EMAIL_AT_RE = re.compile(r"@([\w-]+(?:\.[\w-]+)+)")
_EMAIL_LOCAL_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.+-")
_EMAIL_MAX_AT = 200  # a block with hundreds of '@' is a dump, not a person; bound the work


def _has_email(text: str) -> bool:
    """An address like name@host.tld, except the noreply senders git and GitHub put in every commit trailer. Walks the
    '@' signs instead of one big regex so it stays linear however long the surrounding run of word characters is."""
    pos = 0
    for _ in range(_EMAIL_MAX_AT):
        at = text.find("@", pos)
        if at < 0:
            return False
        pos = at + 1
        m = _EMAIL_AT_RE.match(text, at)
        if not m or at == 0 or text[at - 1] not in _EMAIL_LOCAL_CHARS:
            continue
        start = at
        while start > 0 and at - start < 64 and text[start - 1] in _EMAIL_LOCAL_CHARS:
            start -= 1
        local = text[start:at].lower()
        domain = m.group(1).lower()
        if local.startswith(("noreply", "no-reply")) or domain.endswith("noreply.github.com"):
            continue  # the sender addresses git and GitHub put in every commit trailer
        return True
    # inspected _EMAIL_MAX_AT '@' signs and none was an address: only a 201st '@' is "more than we are willing to inspect"
    return text.find("@", pos) >= 0  # do not send in that case


def _has_command_flag_secret(text: str) -> bool:
    """True when `text` holds a credential flag that belongs to a command word that comes BEFORE it (_COMMAND_FLAG_RULES):
    `curl ... -u user:pass`, `docker login ... -p PASS`, `mysql ... -pPASS`. Two searches per rule over the whole text, so it is
    linear however far the flag sits from the command word."""
    for word_rx, flag_rx in _COMMAND_FLAG_RULES:
        w = word_rx.search(text)
        if w and flag_rx.search(text, w.end()):
            return True
    return False


def egress_withhold_reason(text: str) -> str | None:
    """"secret" | "pii" | None. None is the only answer that lets text leave the machine; it means "none of the known
    shapes matched", NOT "this is safe". Never raises."""
    try:
        # vazio (nenhuma palavra de comando seguida de flag de credencial) → essa regra não casa, as outras seguem; falhou/ilegível
        # (o scan levantou) → o except abaixo devolve "secret" e retém.
        if any(rx.search(text) for rx in _SECRET_RES) or _has_command_flag_secret(text) or _has_token_like_run(text):
            return "secret"
        if any(rx.search(text) for rx in _PII_RES) or _has_email(text):
            return "pii"
    except Exception:  # noqa: BLE001 -- a guard that cannot read the text must not wave it through
        return "secret"
    return None


def sensitive_spans(text: str) -> list[tuple[int, int]]:
    """Character spans of `text` that hold a MULTI-LINE secret, found over the WHOLE output so that a key split across two
    blocks cannot pass by looking harmless in each half: a PEM block from its BEGIN line to the matching END line (to the end
    of the text when the END is missing, i.e. the output was truncated mid-key), and a Kubernetes `kind: Secret` manifest
    to the end of its YAML document. The caller (the Jev planner, a later slice) must withhold any block that overlaps a span. More markers than
    _MAX_SPAN_MARKERS -> the whole output is one span (do not send). Never raises."""
    spans: list[tuple[int, int]] = []
    try:
        for n, m in enumerate(_PEM_BEGIN_RE.finditer(text)):
            if n >= _MAX_SPAN_MARKERS:
                return [(0, len(text))]
            end = _PEM_END_RE.search(text, m.end())
            spans.append((m.start(), end.end() if end else len(text)))
        for n, m in enumerate(_K8S_SECRET_RE.finditer(text)):
            if n >= _MAX_SPAN_MARKERS:
                return [(0, len(text))]
            doc_end = text.find("\n---", m.end())
            spans.append((m.start(), len(text) if doc_end < 0 else doc_end))
    except Exception:  # noqa: BLE001 -- a guard that cannot scan the text must not wave it through
        return [(0, len(text))]
    return spans


def ends_on_secret_key(tail: str) -> bool:
    """True when `tail` (the end of a block) is a bare `password:` / `"token":` whose value is the first line of the NEXT block.
    The caller passes a short tail (200 characters is plenty); trailing whitespace is ignored. Never raises."""
    return bool(_ENDS_WITH_KEY_RE.search(tail.rstrip()))


def _word_open_at_window_end(command: str) -> bool:
    """True when the judged window (COMMAND_JUDGE_CHARS) cuts a word in two AND that word starts inside the logged prefix: the
    rest of it is unjudged, and a shape with no bounded length (a DSN password up to its '@', a long token run) may be completed
    by it. That is the third state -- "cannot tell" -- and it is answered like a match. A command that fits the window, one the
    window ends between words of, and a cut word that starts past the logged prefix (so none of it is logged) are all fine."""
    if len(command) <= COMMAND_JUDGE_CHARS:
        return False
    if command[COMMAND_JUDGE_CHARS - 1].isspace() or command[COMMAND_JUDGE_CHARS].isspace():
        return False
    start = COMMAND_JUDGE_CHARS
    while start > 0 and not command[start - 1].isspace():
        start -= 1
    return start < COMMAND_LOG_CHARS


def loggable_command(command: object) -> str:
    """The command as it may be written to the shared jev-experiment.jsonl (and, in the later Jev slices, shown to Jev): a
    fingerprint (first COMMAND_LOG_CHARS characters), or COMMAND_WITHHELD when the command looks like it carries a credential
    or personal data. The command is JUDGED over COMMAND_JUDGE_CHARS, well past what is logged, because a secret that starts
    inside the logged prefix and ends after it is incomplete in the prefix and passes every rule that needs a minimum length or
    a closing anchor; ANY match in the window withholds, wherever it sits. A word that runs from the logged prefix past the
    window is withheld too (_word_open_at_window_end). The head is judged on its own as well: a shape can stop matching when
    more characters follow it, and that must not turn a withheld prefix into a logged one.
    Not a string (null, a number, a list) -> "": the command is only a fingerprint, not knowing it costs nothing.
    The fixed-rule row uses this, so a token typed into a command line is not left at rest in a log several daily reports
    read. Never raises."""
    if not isinstance(command, str):
        return ""
    head = command[:COMMAND_LOG_CHARS]
    window = command[:COMMAND_JUDGE_CHARS]
    # vazio (nada reconhecido no head nem na janela) → o head é logado; falhou/ilegível (o guard não conseguiu ler) →
    # egress_withhold_reason já devolve "secret" e retém; janela que corta uma palavra aberta a partir do head ("não sei") → retém.
    if egress_withhold_reason(head) or egress_withhold_reason(window) or _word_open_at_window_end(command):
        return COMMAND_WITHHELD
    return head




def _selftest() -> int:
    passed = 0
    failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  ok  {label}")
        else:
            failed += 1
            print(f"  FAIL {label}")

    secrets = {
        "private key": "x\n-----BEGIN RSA PRIVATE KEY-----\nabc\n",
        "sk- token": "key is sk-abcdefghijklmnop1234",
        "github token": "ghp_" + "a" * 30,
        "aws key id": "AKIA" + "A" * 16,
        "jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
        "authorization header": "Authorization: Bearer abcdef123456789",
        "password assignment": "export DB_PASSWORD=hunter2hunter2",
        "token assignment": "token: 0123456789abcdef",
        # the review's bypass: a quote between the name and the separator (JSON / python-dict dumps)
        "json password": '{"password": "hunter2hunter2"}',
        "json api_key with space before colon": '{"api_key" : "k3y-valu3-here"}',
        "single-quoted dict token": "{'token': 'abcdef012345'}",
        "x-api-key header": "X-Api-Key: 0123456789abcdef",
        "cookie header": "Cookie: session=abcdef0123456789",
        "set-cookie header": "Set-Cookie: sid=abcdef0123456789; HttpOnly",
        "dsn with password": "DATABASE_URL=postgres://app:s3cretpw@db.internal:5432/app",
        "url with credentials": "git clone https://user:ghpassword12@github.com/x/y.git",
        "long mixed-case token": "id: Zk3Jq9XvB2nM7LpA4sD8fG1hT6yU0wRe",
        "aws secret key assignment": "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG",
        "pem certificate": "-----BEGIN CERTIFICATE-----\nMIIB",
    }
    for label, sample in secrets.items():
        ok(f"egress guard: {label} -> secret", egress_withhold_reason(sample) == "secret")
    pii = {
        "CPF": "cliente 123.456.789-09 ativo",
        "CNPJ": "empresa 12.345.678/0001-95",
        "phone +55": "ligar +55 (31) 99999-8888",
        "phone (31)": "tel (31) 99999-8888",
        "whatsapp number": "lead 5531999998888 respondeu",
        "whatsapp jid": "from 5531999998888@s.whatsapp.net",
        "email": "contato: maria.silva@example.com.br",
    }
    for label, sample in pii.items():
        ok(f"egress guard: {label} -> pii", egress_withhold_reason(sample) == "pii")
    harmless = {
        "git sha": "commit 9f3c2a1b7d4e5f60718293a4b5c6d7e8f9012345",
        "epoch": "ts=1793467170 started",
        "bead id": "see ga-d0hm85 and /Users/athos/gt/x/y.py",
        "noreply trailer": "Co-Authored-By: Claude <noreply@anthropic.com>",
        "github noreply": "Athos <12345+athos@users.noreply.github.com>",
        "pytest line": "test_mod.py::test_one PASSED [ 12%]",
        "tokens counter": "tokens_would_save=100",
        "sha256 (hex only)": "sha256:" + "ab12" * 16,
        "toolu id": "toolu_01A09q90qw90lq917835",
        "worktree path": "/Users/athos/gt/.gc-worktrees/ga-d0hm85/.gascity-gastown-hq/scripts/cut_output_jev.py",
        "branch name": "feat/ga-d0hm85-jev-na-sombra-do-corte-de-saida-fase-2-da-ga-wk0qi2",
        "plain url": "see https://github.com/athosmartins/gastown/pull/70 for details",
        "author word": "author: Athos",
    }
    for label, sample in harmless.items():
        ok(f"egress guard: {label} is NOT withheld", egress_withhold_reason(sample) is None)
    ok("loggable_command: a plain command is kept (first COMMAND_LOG_CHARS characters)", loggable_command("ls -la " + "x" * 400) == ("ls -la " + "x" * 400)[:COMMAND_LOG_CHARS])
    ok("loggable_command: a command with a bearer token is replaced by the placeholder", loggable_command("curl -H 'Authorization: Bearer abcdef0123456789'") == COMMAND_WITHHELD)
    past = loggable_command("x" * 310 + " password=hunter2hunter2")
    ok("loggable_command: a credential just PAST the logged prefix, inside the judged window, withholds the command (gate fix 1: the command is judged BEFORE it is cut)",
       past == COMMAND_WITHHELD)
    ok("loggable_command: not a string -> empty, never a raise", all(loggable_command(v) == "" for v in (None, 123, ["ls"], b"x")))

    # ---- gate feedback attempt 1 (ga-d0hm85.1), blocking issue 1: a credential that STARTS inside the logged prefix and ENDS after
    # it was judged on its cut-off prefix (every shape that needs a minimum length or a closing anchor saw an incomplete secret) and
    # the prefix was logged. The THIRD state -- "the cut-off tail may complete a secret" -- must not be handled as "no secret".
    straddle_shapes = {
        "dsn password (the '@' is past the cut)": "psql postgres://app:Zk3Jq9XvB2nM@db.internal:5432/app",
        "ghp_ token": "ghp_" + "a1" * 20,
        "generic mixed-case token": "id: " + "Zk3Jq9XvB2nM7LpA4sD8fG1hT6yU0wRe" * 2,
        "sk- key": "key sk-" + "a1b2c3d4e5" * 5,
        "bearer token": "curl -H 'Authorization: Bearer " + "abcdef0123" * 4 + "'",
        "password= value": "export DB_PASSWORD=hunter2hunter2",
        "slack token": "notify xoxb-" + "1234567890-" * 4 + "abc",
    }
    for label, shape in straddle_shapes.items():
        # k = how many characters of the secret land inside the logged prefix: 0 (all past the cut) .. len(shape) (all inside)
        leaks = [k for k in range(len(shape) + 1)
                 if loggable_command("x" * (COMMAND_LOG_CHARS - k - 1) + " " + shape + " tail") != COMMAND_WITHHELD]
        ok(f"straddle: {label} is judged uncut as a secret AND the command is withheld at every cut offset 0..{len(shape)}",
           egress_withhold_reason(shape) is not None and not leaks)
        if leaks:
            print(f"       offsets whose logged prefix leaks part of the secret: {leaks}")
    far = "ls " + "word " * 1000 + "password=hunter2hunter2"  # the credential sits past the judged window: not logged, not judged
    ok("loggable_command: a credential far past the judged window is neither judged nor logged -- the head is kept (the window is a bound, not 'withhold every long command')",
       len(far) > COMMAND_JUDGE_CHARS and loggable_command(far) == far[:COMMAND_LOG_CHARS] and "hunter2" not in loggable_command(far))
    open_dsn = "psql postgres://app:" + "q" * (COMMAND_JUDGE_CHARS + 900) + "@db/app"
    ok("loggable_command: a word that starts INSIDE the logged prefix and runs past the judged window (its closing '@' is unjudged) is withheld -- unknown is not 'no secret'",
       loggable_command(open_dsn) == COMMAND_WITHHELD)
    late_word = "echo " + "a " * 200 + "z" * (COMMAND_JUDGE_CHARS + 50)  # the cut word starts at index 405: none of it is logged
    ok("loggable_command: ... but a long command whose window ends between words, or inside a word that started past the logged prefix, keeps its head",
       loggable_command("ls " + "word " * 1000) == ("ls " + "word " * 1000)[:COMMAND_LOG_CHARS]
       and loggable_command(late_word) == late_word[:COMMAND_LOG_CHARS])
    # the cut can also END a shape that the longer text no longer matches: AKIA + 16 upper-case chars followed by MORE word characters
    # is not a key id (the \b fails), but the head ends right after the 16th. The head is judged too, so this stays withheld.
    akia = "x" * (COMMAND_LOG_CHARS - 21) + " AKIA" + "B" * 30
    ok("loggable_command: the head is judged as well as the window (a shape the longer text stops matching still withholds)",
       egress_withhold_reason(akia) is None and loggable_command(akia) == COMMAND_WITHHELD)
    ok("e-mail scan boundary: exactly _EMAIL_MAX_AT non-address '@' signs are all inspected and pass; one more is withheld",
       egress_withhold_reason(" @x" * 200) is None and egress_withhold_reason(" @x" * 201) == "pii")
    for label, sample in {
        "long flag with a space separator: --password VALUE": "mytool --password Hunter2Hunter2 --host db",
        "long flag with a space separator: --token VALUE": "deploy --token abcdef0123456789 now",
        "Authorization: Basic <base64>": "curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA==' https://x",
        "Authorization: Token <value>": "curl -H 'Authorization: Token abcdef0123456789' https://x",
        "Slack webhook URL": "curl -X POST https://hooks.slack.com/" + "services/T01234567/B01234567/" + "abcdefghijklmnopqrstuvwx",
        "curl -u user:pass": "curl -u admin:s3cretpw https://api.example.invalid/x",
        "docker login -p PASS": "docker login -u me -p s3cretpw registry.example.invalid",
        "mysql -pPASS": "mysql -h db -u root -ps3cretpw app",
    }.items():
        ok(f"egress guard (mainstream shapes the first cut missed): {label} -> secret", egress_withhold_reason(sample) == "secret")
    # ---- security review of the gate-fix commit: the curl / docker login / mysql rules looked for the flag at most 200 characters past
    # the command word, so `curl <a few headers> -u user:pass` (flag at 200..300, INSIDE the logged prefix) passed. The flag is now
    # looked for at any distance after the first command word (see the no-segmentation cases below for why not "per segment").
    far_flag = {
        "curl -u": ("curl https://api.example.invalid/x", " -u admin:s3cretpw"),
        "docker login -p": ("docker login registry.example.invalid", " -u me -p s3cretpw"),
        "mysql -pPASS": ("mysql -h db -u root", " -ps3cretpw app"),
    }
    for label, (cmd_word, flag) in far_flag.items():
        for gap in (150, 250, 450, 1500, 3500):
            sample = cmd_word + " --opt" * (gap // 6) + flag
            ok(f"far flag: {label}, flag ~{gap} characters after the command word -> secret, and the command is withheld",
               egress_withhold_reason(sample) == "secret" and loggable_command(sample) == COMMAND_WITHHELD)
    # second security review: splitting the text into "segments" at ';' '|' '&' newline is wrong without a shell parser. A separator
    # INSIDE quotes (a Content-Type header with `; charset=`) or a backslash-continued multi-line curl put the word and its flag in
    # different segments. So there is no segmentation: the flag is looked for anywhere after the first command word, and a flag
    # that merely sits past some separator is withheld too (a false positive costs one command; a false negative leaks a credential).
    for label, sample in {
        "separator inside quotes": "curl -H 'Content-Type: application/json; charset=utf-8' -u admin:s3cretpw https://x",
        "pipe inside double quotes": 'curl -H "X-Filter: a|b" -u admin:s3cretpw https://x',
        "ampersand inside a URL": "curl 'https://x/?a=1&b=2' -u admin:s3cretpw",
        "backslash-continued multi-line": "curl -X POST \\\n  -H 'A: b' \\\n  -u admin:s3cretpw \\\n  https://x",
        "attached -u (no space)": "curl -uadmin:s3cretpw https://x",
        "docker login attached -p": "docker login -u me -ps3cretpw registry.example.invalid",
        "docker login --password=VALUE": "docker login -u me --password=s3cretpw registry.example.invalid",
        "mysql after a separator": "cd /srv; mysql -h db -u root -ps3cretpw app",
        "flag past a separator is still withheld (no segmentation)": "curl https://x ; ls -u admin:s3cretpw",
        "the first command word counts (a second one after the flag does not hide it)": "curl -u admin:s3cretpw https://x ; curl https://y",
    }.items():
        ok(f"no segmentation: {label} -> secret, and the command is withheld",
           egress_withhold_reason(sample) == "secret" and loggable_command(sample) == COMMAND_WITHHELD)
    ok("no segmentation: a flag BEFORE the first command word, or a similar-looking flag, is not a credential flag",
       all(egress_withhold_reason(s) is None for s in (
           "ls -u admin:s3cretpw ; curl https://x",
           "echo -u admin:s3cretpw curl",
           "curl --upload-file notes.txt https://x",
           "curl --user-agent mytool/1.0 https://x",
           "curl --user-agent=Mozilla:5.0 https://x",
           "curl -sS -o out.txt https://x",
           "docker login --pull-timeout 5 registry.example.invalid",
           "mysql -h db -u root -p app")))
    for label, sample in {
        "git push -u": "git push -u origin main",
        "docker run -u uid:gid": "docker run -u app server",
        "mysql with a bare -p (prompts)": "mysql -h db -u root -p app",
        "mysql -P is the PORT, not a password": "mysql -h db -P3306 -u root app",
        "--token-file path": "tool --token-file /etc/tool/token.txt",
        "--password-stdin": "docker login --password-stdin < pw.txt",
        "authorization in prose": "authorization: ok",
    }.items():
        ok(f"egress guard: {label} is NOT withheld", egress_withhold_reason(sample) is None)
    ok("a long mixed-case run is still caught after the rewrite (and a hex-only run of the same length is not)",
       egress_withhold_reason("k=" + "aB3" * 20) == "secret" and egress_withhold_reason("sha " + "ab12" * 16) is None)
    ok("review finding 3: a secret that FOLLOWS a long benign prefix in the same run is caught (the 128-char window missed it)",
       egress_withhold_reason("id=" + "a" * 300 + "Zk3Jq9XvB2nM7LpA4sD8fG1hT6") == "secret"
       and egress_withhold_reason("id=" + "a" * 5000 + "-" + "b" * 5000) is None)
    many_hex = " ".join(("%032x" % i) for i in range(2500))  # 2500 benign 32-char hex runs: more than the scan will inspect
    ok("review finding 3: more long runs than the scan will inspect is WITHHELD, not waved through (inert on hostile input)",
       egress_withhold_reason(many_hex) == "secret" and egress_withhold_reason(" ".join(("%032x" % i) for i in range(50))) is None)
    ok("review finding 3: ... and a secret placed AFTER 2100 benign long runs cannot hide behind them",
       egress_withhold_reason(" ".join(("%032x" % i) for i in range(2100)) + " Zk3Jq9XvB2nM7LpA4sD8fG1hT6yU0wRe") == "secret")


    # ---- multi-line secrets over the WHOLE output (the second review's block-edge bypass), asserted on the spans themselves ----
    pem = "-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join("MIIEowIBAAKCAQEA" + "0123456789abcdef" * 4 for _ in range(5)) + "\n-----END RSA PRIVATE KEY-----\n"
    doc = "before words\n\n" + pem + "\nafter words\n"
    spans = sensitive_spans(doc)
    ok("sensitive_spans: a PEM key BEGIN..END is one span covering the markers and the body", len(spans) == 1 and doc[spans[0][0]:spans[0][1]] == pem.rstrip("\n"))
    ok("sensitive_spans: the text before and after the key is outside the span", spans and spans[0][0] > doc.index("before") and spans[0][1] < doc.index("after"))
    cut = "words\n\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA"
    tspans = sensitive_spans(cut)
    ok("sensitive_spans: a key TRUNCATED mid-way (BEGIN, no END) runs to the end of the text", len(tspans) == 1 and tspans[0][1] == len(cut))
    k8s = "a: 1\n\napiVersion: v1\nkind: Secret\ndata:\n  v: aGk=\n---\nkind: ConfigMap\n"
    kspans = sensitive_spans(k8s)
    ok("sensitive_spans: a `kind: Secret` manifest runs to the end of its YAML document and stops at ---",
       len(kspans) == 1 and "aGk=" in k8s[kspans[0][0]:kspans[0][1]] and "ConfigMap" not in k8s[kspans[0][0]:kspans[0][1]])
    ok("sensitive_spans: plain text has no span", sensitive_spans("just words\n\nand more words\n") == [])
    ok("sensitive_spans: more markers than the scan will inspect -> the WHOLE output is one span (do not send)",
       sensitive_spans("-----BEGIN X-----\n" * 60) == [(0, len("-----BEGIN X-----\n" * 60))])
    ok("sensitive_spans: a `kind: Secret` flood is the whole output too", sensitive_spans("kind: Secret\n" * 60) == [(0, len("kind: Secret\n" * 60))])
    ok("e-mail scan: more '@' signs than it will inspect is WITHHELD (inert), while a few non-address '@' are fine",
       egress_withhold_reason(" @x" * 250) == "pii" and egress_withhold_reason(" @x" * 20) is None)
    ok("ends_on_secret_key: a block ending on a bare `password:` says the next block holds the value", ends_on_secret_key("db:\n  password:\n") and ends_on_secret_key('x\n  "token" :  '))
    ok("ends_on_secret_key: a key WITH its value, or ordinary text, does not", not ends_on_secret_key("password: hunter2hunter2") and not ends_on_secret_key("nothing here\n"))

    t_lin = time.time()
    for hostile in ("A1" * 60000, ("a-" * 30000) + "Z9", "-----BEGIN X-----" * 400, "kind: Secret\n" * 400, "token:" * 20000, ("Ab1" * 40 + " ") * 5000,
                    "curl " * 20000, "docker login " * 8000, "mysql " * 16000, "--token " * 12000, "Authorization:" * 8000,
                    "curl;" * 25000, "curl -u " * 12000, ("curl -u " + "a" * 63 + " ") * 1500, ("mysql -p" + " ") * 12000):
        sensitive_spans(hostile)
        egress_withhold_reason(hostile[:10000])
    ok("the guard and the span scan stay linear on hostile 100k+ character inputs (production-shaped; bound generous, not tight, so load 60 cannot flake it)",
       time.time() - t_lin < 10.0)

    print(f"cut_output_egress selftest: passed={passed} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(_selftest())
    print(__doc__)
    sys.exit(0)
