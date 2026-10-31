#!/usr/bin/env python3
"""cut_output_egress.py (ga-d0hm85, slice 1/3) -- the egress guard of the cut-large-output SHADOW front.

## Contents
  What it is · Why it exists · Limits · CLI

WHAT IT IS. Pure functions that decide whether a piece of command output (or a command line) LOOKS like a credential or
personal data, so that it is neither sent to a third party (the Jev tier, cut_output_jev.py) nor left at rest in the shared
jev-experiment.jsonl. egress_withhold_reason() answers "secret" | "pii" | None for one block of text; sensitive_spans()
finds MULTI-LINE secrets over the WHOLE output (a PEM key BEGIN..END, a truncated one, a `kind: Secret` manifest) so a key
split across two blocks cannot look harmless in each half; ends_on_secret_key() says a block ends on a bare `password:` whose
value starts the next one; loggable_command() is the command as it may be logged or sent.

WHY IT EXISTS. Phase 1 logged `command[:300]` raw, so a token typed into a command line sat in a log several daily reports read.
The Jev tier would also put block text in front of Cloudflare Workers AI -- outward-facing and not undoable. Two automated
security reviews of that tier found bypasses (a quote between name and separator, a DSN, a key split across blocks, a secret
after a long benign prefix, a cap that failed OPEN); every one is a test below.

LIMITS. A best-effort filter, not a proof: a name or a street address in plain prose is not detected, and an unusual secret
format passes. None means "none of the known shapes matched", NOT "safe". Every bound fails toward WITHHOLDING (more '@' signs, more
long runs, more markers than the scan will inspect -> do not send). Every pattern is linear on hostile input.

CLI:
  python3 cut_output_egress.py selftest     pure, no network, no files
"""
from __future__ import annotations

import re
import sys
import time

COMMAND_LOG_CHARS = 300  # the command we log (and send) is a fingerprint, not a full replay
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
    return True  # more '@' signs than we are willing to inspect: do not send


def egress_withhold_reason(text: str) -> str | None:
    """"secret" | "pii" | None. None is the only answer that lets text leave the machine; it means "none of the known
    shapes matched", NOT "this is safe". Never raises."""
    try:
        if any(rx.search(text) for rx in _SECRET_RES) or _has_token_like_run(text):
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
    to the end of its YAML document. Any block that overlaps a span is withheld by plan_send(). More markers than
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


def loggable_command(command: object) -> str:
    """The command as it may be written to the shared jev-experiment.jsonl and shown to Jev: a fingerprint (first
    COMMAND_LOG_CHARS characters), or COMMAND_WITHHELD when those characters look like a credential or personal data.
    Not a string (null, a number, a list) -> "": the command is only a fingerprint, not knowing it costs nothing.
    The fixed-rule row and the Jev row both use this, so a token typed into a command line is not left at rest in a log
    several daily reports read. Never raises."""
    if not isinstance(command, str):
        return ""
    head = command[:COMMAND_LOG_CHARS]
    return COMMAND_WITHHELD if egress_withhold_reason(head) else head




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
    past = loggable_command("x" * 310 + "password=hunter2hunter2")
    ok("loggable_command: a credential PAST the logged prefix is cut off with it -- not logged, not sent, and the prefix is not mistaken for one",
       "hunter2" not in past and past == "x" * COMMAND_LOG_CHARS)
    ok("loggable_command: not a string -> empty, never a raise", all(loggable_command(v) == "" for v in (None, 123, ["ls"], b"x")))
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
    for hostile in ("A1" * 60000, ("a-" * 30000) + "Z9", "-----BEGIN X-----" * 400, "kind: Secret\n" * 400, "token:" * 20000, ("Ab1" * 40 + " ") * 5000):
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
