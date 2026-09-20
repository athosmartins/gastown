#!/usr/bin/env python3
"""ga-5bxuam codemod: remove the early-exit reader from `<writer> | grep -q ...`.

    <writer> | grep -qE 'pat' && x      ->   <writer> | grep -E 'pat' >/dev/null && x

Why: under `set -o pipefail` a reader that exits on its first match (grep -q)
can close the pipe while the writer is still writing.  The writer then dies of
SIGPIPE, pipefail makes the pipeline's status the writer's 141, and a MATCH is
reported as "no match".  Without -q grep reads to EOF, so the writer always
finishes; the exit status is still grep's (0 = match) and pipefail still
reflects a genuinely failing writer.

The scanner below is a small shell tokenizer (quotes, $(...), `...`, ${...},
heredocs, comments) so an edit is only made in CODE context.

usage:  pipefail-grepq-codemod.py [--apply] ROOT file...   (files relative to ROOT; @listfile ok)
        without --apply it only reports (per file: sites, rewritten, skipped, anomalies) and changes nothing.

A site is skipped (and reported as SKIP) when: the file sets no pipefail before it, the flag cluster is
quoted, grep is not the last stage, stdout is redirected somewhere other than /dev/null, or the line carries
the shared allowlist comment  # erro-vs-vazio: ok <razao>.
"""
import re
import sys

GREPS = {"grep", "egrep", "fgrep", "ugrep", "rg"}
ARG_OPTS = set("efmABCdD")          # short options that take an argument


class Scan:
    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.events = []            # (ctx, kind, start, end, text)
        self.ctx_seq = 0
        self.pending_heredocs = []  # (delim, strip_tabs)
        self.anomalies = []

    # ---------------------------------------------------------------- helpers
    def new_ctx(self):
        self.ctx_seq += 1
        return self.ctx_seq

    def emit(self, ctx, kind, a, b):
        self.events.append((ctx, kind, a, b, self.s[a:b]))

    # ---------------------------------------------------------------- heredoc
    def consume_heredocs(self, i):
        """i is just after a newline; skip heredoc bodies queued on the line."""
        s, n = self.s, self.n
        while self.pending_heredocs:
            delim, strip = self.pending_heredocs.pop(0)
            while i < n:
                j = s.find("\n", i)
                line = s[i:] if j < 0 else s[i:j]
                i = n if j < 0 else j + 1
                cmp = line.lstrip("\t") if strip else line
                if cmp == delim:
                    break
            else:
                self.anomalies.append(f"heredoc {delim!r} never terminated")
        return i

    # ------------------------------------------------------------------ code
    def scan_code(self, i, ctx, closer):
        s, n = self.s, self.n
        depth = 0                    # nested '(' (subshell/group) inside this ctx
        while i < n:
            c = s[i]
            if c in " \t\r":
                i += 1
                continue
            if c == "\n":
                self.emit(ctx, "op", i, i + 1)
                i += 1
                if self.pending_heredocs:
                    i = self.consume_heredocs(i)
                continue
            if c == "\\" and i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            if c == "#":
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "`":
                if closer == "`":
                    return i
                i = self.scan_code(i + 1, self.new_ctx(), "`")
                if i < n and s[i] == "`":
                    i += 1
                else:
                    self.anomalies.append("unterminated backtick")
                continue
            if c == ")":
                if depth > 0:
                    depth -= 1
                    self.emit(ctx, "op", i, i + 1)
                    i += 1
                    continue
                if closer == ")":
                    return i
                self.emit(ctx, "op", i, i + 1)      # case pattern ')' etc.
                i += 1
                continue
            if c == "(":
                depth += 1
                self.emit(ctx, "op", i, i + 1)
                i += 1
                continue
            if c == "|":
                if s.startswith("||", i):
                    self.emit(ctx, "op", i, i + 2)
                    i += 2
                elif s.startswith("|&", i):
                    self.emit(ctx, "op", i, i + 2)
                    i += 2
                else:
                    self.emit(ctx, "op", i, i + 1)
                    i += 1
                continue
            if c == "&":
                if s.startswith("&&", i):
                    self.emit(ctx, "op", i, i + 2)
                    i += 2
                    continue
                if s.startswith("&>", i):            # &> / &>> redirect word
                    i = self.scan_word(i, ctx)
                    continue
                self.emit(ctx, "op", i, i + 1)
                i += 1
                continue
            if c == ";":
                k = i + 1
                while k < n and s[k] in ";&":
                    k += 1
                self.emit(ctx, "op", i, k)
                i = k
                continue
            i = self.scan_word(i, ctx)
        return i

    # ------------------------------------------------------------------ word
    def scan_word(self, i, ctx):
        s, n = self.s, self.n
        start = i
        while i < n:
            c = s[i]
            if c in " \t\r\n":
                break
            if c == "\\":
                i += 2
                continue
            if c == "'":
                j = s.find("'", i + 1)
                if j < 0:
                    self.anomalies.append("unterminated single quote")
                    i = n
                    break
                i = j + 1
                continue
            if c == '"':
                i = self.scan_dq(i, ctx)
                continue
            if c == "$" and i + 1 < n:
                d = s[i + 1]
                if d == "'":
                    j = i + 2
                    while j < n and s[j] != "'":
                        j += 2 if s[j] == "\\" else 1
                    i = j + 1
                    continue
                if d == '"':
                    i = self.scan_dq(i + 1, ctx)
                    continue
                if d == "(":
                    if s.startswith("$((", i):
                        i = self.skip_arith(i)
                    else:
                        i = self.scan_sub(i + 2, ")")
                    continue
                if d == "{":
                    i = self.skip_brace(i + 2)
                    continue
            if c == "`":
                i = self.scan_sub(i + 1, "`")
                continue
            if c in "<>" and i + 1 < n and s[i + 1] == "(":     # process substitution
                i = self.scan_sub(i + 2, ")")
                continue
            if c == "&":
                if i > start and s[i - 1] in "<>":              # >&2, <&3
                    i += 1
                    continue
                break
            if c == "|":
                if i > start and s[i - 1] == ">":               # >| noclobber
                    i += 1
                    continue
                break
            if c in ";()":
                break
            i += 1
        word = s[start:i]
        self.emit(ctx, "tok", start, i)
        # heredoc introducer?  <<WORD, <<-WORD, <<'WORD', 2<<EOF ... (not <<<)
        m = re.match(r"^[0-9]*<<(?!<)(-?)(.*)$", word, re.S)
        if m:
            strip, rest = m.group(1) == "-", m.group(2)
            if rest == "":
                # delimiter is the next word; peek
                j = i
                while j < n and s[j] in " \t":
                    j += 1
                k = j
                while k < n and s[k] not in " \t\n;|&()":
                    k += 1
                rest = s[j:k]
            delim = re.sub(r"""^['"\\]?(.*?)['"]?$""", r"\1", rest.strip())
            delim = delim.replace("\\", "")
            if delim:
                self.pending_heredocs.append((delim, strip))
        return i

    def scan_dq(self, i, ctx):
        s, n = self.s, self.n
        i += 1
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == '"':
                return i + 1
            if c == "$" and i + 1 < n:
                d = s[i + 1]
                if d == "(":
                    if s.startswith("$((", i):
                        i = self.skip_arith(i)
                    else:
                        i = self.scan_sub(i + 2, ")")
                    continue
                if d == "{":
                    i = self.skip_brace(i + 2)
                    continue
            if c == "`":
                i = self.scan_sub(i + 1, "`")
                continue
            i += 1
        self.anomalies.append("unterminated double quote")
        return n

    def scan_sub(self, i, closer):
        """nested command context; i is just after the opener; returns index after closer."""
        j = self.scan_code(i, self.new_ctx(), closer)
        if j < self.n and self.s[j] == closer:
            return j + 1
        self.anomalies.append(f"unterminated command substitution (closer {closer!r})")
        return j

    def skip_arith(self, i):
        s, n = self.s, self.n
        depth = 0
        j = i + 1
        while j < n:
            if s[j] == "(":
                depth += 1
            elif s[j] == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        self.anomalies.append("unterminated arithmetic")
        return n

    def skip_brace(self, i):
        s, n = self.s, self.n
        depth = 1
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == "'":
                j = s.find("'", i + 1)
                i = n if j < 0 else j + 1
                continue
            if c == '"':
                i = self.scan_dq(i, 0)
                continue
            if c == "$" and i + 1 < n and s[i + 1] == "{":
                depth += 1
                i += 2
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        self.anomalies.append("unterminated ${")
        return n


# --------------------------------------------------------------- dequoting
def dequote(t):
    """best-effort value of a (mostly) literal word; None if it has expansions."""
    if "$" in t or "`" in t:
        return None
    out, i = [], 0
    while i < len(t):
        c = t[i]
        if c == "\\" and i + 1 < len(t):
            out.append(t[i + 1])
            i += 2
        elif c == "'":
            j = t.find("'", i + 1)
            out.append(t[i + 1:j] if j > 0 else t[i + 1:])
            i = (j + 1) if j > 0 else len(t)
        elif c == '"':
            j = i + 1
            buf = []
            while j < len(t) and t[j] != '"':
                if t[j] == "\\" and j + 1 < len(t):
                    buf.append(t[j + 1])
                    j += 2
                else:
                    buf.append(t[j])
                    j += 1
            out.append("".join(buf))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def cmd_words(toks):
    """skip leading assignments / `command` / `builtin` / env prefixes; return (index of argv0)"""
    k = 0
    while k < len(toks):
        w = toks[k][4]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
            k += 1
            continue
        if w in ("command", "builtin", "exec", "!", "time", "{", "then", "do", "else", "elif", "if", "while", "until"):
            k += 1
            continue
        if w == "env":
            k += 1
            continue
        break
    return k


def analyze_grep(toks, k):
    """toks[k] is the grep word.  Returns dict(q_tok=index, cluster_edit=(a,b,new) | remove=(a,b),
    stdout_redirected=bool, dynamic=bool) or None if there is no -q flag."""
    name = toks[k][4].rsplit("/", 1)[-1]
    if name not in GREPS:
        return None
    q = None
    dynamic = False
    expect_arg = False
    after_dd = False
    stdout_redir = None
    for idx in range(k + 1, len(toks)):
        a, b, w = toks[idx][2], toks[idx][3], toks[idx][4]
        # redirects
        if re.match(r"^(&>>?|[0-9]*>>?)(?!&)", w):
            fd = re.match(r"^([0-9]*)", w).group(1)
            is_out = w.startswith("&>") or fd in ("", "1")
            if is_out:
                stdout_redir = w
            continue
        if re.match(r"^[0-9]*>&", w) or re.match(r"^[0-9]*<", w):
            continue
        if expect_arg:
            expect_arg = False
            continue
        if after_dd:
            continue
        dq = dequote(w)
        if dq is None:                      # has an expansion: could be dynamic flags or the pattern; leave it
            continue
        if dq == "--":
            after_dd = True
            continue
        if dq in ("--quiet", "--silent") and w == dq:
            q = ("remove", a, b, idx)
            continue
        if dq.startswith("--"):
            if dq in ("--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context", "--directories", "--devices", "--include", "--exclude"):
                expect_arg = True
            continue
        if dq.startswith("-") and len(dq) > 1:
            # cluster; only trust it when unquoted (quoted clusters are option-like to grep too, but
            # we do not rewrite those)
            cl = dq[1:]
            for pos, ch in enumerate(cl):
                if ch in ARG_OPTS:
                    if pos == len(cl) - 1:
                        expect_arg = True
                    break
                if ch == "q":
                    if w == dq:                    # unquoted plain word
                        q = ("cluster", a, b, idx, w)
                    else:
                        q = ("quoted-cluster", a, b, idx, w)
                    break
    return {"q": q, "stdout": stdout_redir, "name": name}


def analyze(src):
    sc = Scan(src)
    sc.scan_code(0, sc.new_ctx(), None)
    # group events by ctx, keep order
    by_ctx = {}
    for ev in sc.events:
        by_ctx.setdefault(ev[0], []).append(ev)
    sites = []
    pipefail_pos = None
    for ctx, evs in by_ctx.items():
        segs = [[]]
        seps = []
        for ev in evs:
            if ev[1] == "op":
                seps.append(ev[4])
                segs.append([])
            else:
                segs[-1].append(ev)
        # segs[i] separated from segs[i+1] by seps[i]
        for i, seg in enumerate(segs):
            if not seg:
                continue
            k = cmd_words(seg)
            if k < len(seg):
                w0 = seg[k][4]
                if w0 in ("set", "shopt") and any("pipefail" in t[4] for t in seg[k + 1:]):
                    if pipefail_pos is None or seg[k][2] < pipefail_pos:
                        pipefail_pos = seg[k][2]
            # reader stage?  previous separator must be a pipe
            if i == 0 or seps[i - 1] not in ("|", "|&"):
                continue
            if k >= len(seg):
                continue
            info = analyze_grep(seg, k)
            if not info or not info["q"]:
                continue
            sites.append({"seg": seg, "k": k, "info": info,
                          "start": seg[k][2], "end": seg[-1][3],
                          "has_more_pipe": (i < len(seps) and seps[i] in ("|", "|&"))})
    return sc, sites, pipefail_pos


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def rewrite(src, sites, pipefail_pos):
    edits = []          # (pos_a, pos_b, replacement)
    report = []
    skipped = []
    for st in sites:
        info = st["info"]
        q = info["q"]
        ln = line_of(src, st["start"])
        if pipefail_pos is None or st["start"] < pipefail_pos:
            skipped.append((ln, "no-pipefail-before", src[st["start"]:st["end"]]))
            continue
        # shared allowlist: a physical line of the statement carrying "# erro-vs-vazio: ok <razao>"
        ls = src.rfind("\n", 0, st["start"]) + 1
        le = src.find("\n", st["end"])
        le = len(src) if le < 0 else le
        if re.search(r"erro-vs-vazio:\s*ok", src[ls:le], re.I):
            skipped.append((ln, "allowlisted", src[st["start"]:st["end"]]))
            continue
        if q[0] == "quoted-cluster":
            skipped.append((ln, "quoted-flag-cluster", src[st["start"]:st["end"]]))
            continue
        if st["has_more_pipe"]:
            skipped.append((ln, "grep-not-last-stage", src[st["start"]:st["end"]]))
            continue
        so = info["stdout"]
        if so is not None and so not in (">/dev/null", "1>/dev/null", "&>/dev/null", ">/dev/null"):
            skipped.append((ln, f"stdout-redirected-to {so}", src[st["start"]:st["end"]]))
            continue
        e = []
        if q[0] == "cluster":
            _, a, b, idx, w = q
            new = w.replace("q", "", 1)
            if new == "-":
                # remove the whole word plus one preceding space
                aa = a - 1 if a > 0 and src[a - 1] == " " else a
                e.append((aa, b, ""))
            else:
                e.append((a, b, new))
        else:                                   # remove --quiet / --silent
            _, a, b, idx = q
            aa = a - 1 if a > 0 and src[a - 1] == " " else a
            e.append((aa, b, ""))
        if so is None:
            e.append((st["end"], st["end"], " >/dev/null"))
        edits.extend(e)
        report.append((ln, src[st["start"]:st["end"]], None))
    return edits, report, skipped


def apply_edits(src, edits):
    edits = sorted(edits, key=lambda t: (t[0], t[1]), reverse=True)
    out = src
    last = len(src) + 1
    for a, b, r in edits:
        assert b <= last, "overlapping edits"
        out = out[:a] + r + out[b:]
        last = a
    return out


def main(argv):
    apply = "--apply" in argv
    argv = [a for a in argv if not a.startswith("--")]
    root, files = argv[0], argv[1:]
    if files and files[0].startswith("@"):
        files = [l.strip() for l in open(files[0][1:]) if l.strip()]
    tot_sites = tot_skipped = 0
    for rel in files:
        path = f"{root}/{rel}"
        src = open(path, encoding="utf-8", errors="surrogateescape").read()
        sc, sites, pf = analyze(src)
        edits, report, skipped = rewrite(src, sites, pf)
        new = apply_edits(src, edits)
        tot_sites += len(report)
        tot_skipped += len(skipped)
        print(f"== {rel}: sites={len(sites)} rewritten={len(report)} skipped={len(skipped)} pipefail@{pf and line_of(src, pf)} anomalies={sc.anomalies[:3]}")
        for ln, why, txt in skipped:
            print(f"   SKIP L{ln} [{why}] {txt[:120]!r}")
        if apply and new != src:
            open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
    print(f"# total rewritten={tot_sites} skipped={tot_skipped}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
