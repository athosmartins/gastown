import re, sys
def blocks(text, maxlevel=2):
    """split at markdown headings of level<=maxlevel, ignoring fenced code. -> [(heading, chars)]"""
    out, cur, fence, buf = [], "(preamble)", False, []
    def flush():
        out.append((cur, len("\n".join(buf))))
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        m = re.match(r"^(#{1,%d}) (.*)" % maxlevel, line) if not fence else None
        if m:
            flush(); cur = m.group(0)[:90]; buf = [line]
        else:
            buf.append(line)
    flush()
    return out
if __name__ == "__main__":
    t = open(sys.argv[1]).read()
    tot = len(t)
    for h, n in blocks(t, int(sys.argv[2]) if len(sys.argv) > 2 else 2):
        print(f"{n:7d} {100*n/tot:5.1f}%  {h}")
    print(f"{tot:7d} TOTAL")
