"""Mechanical check: every number quoted in the report tables == the saved result files. Usage: verify-doc.py <report dir>"""
import re, json, sys

D = sys.argv[1]
doc = open(D + "/../agent-browser-vs-playwright-mcp-ga-30455bt.md", encoding="utf8").read()
rep = open(D + "/results/report.txt", encoding="utf8").read()
micro = json.load(open(D + "/results/micro.json"))
ok = True


def chk(name, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(("OK   " if cond else "FAIL ") + name + ((" :: " + detail) if (detail and not cond) else ""))


num = lambda s: int(s.replace(".", ""))
B = r"\**"  # a cell may be bold

# ---- section 3 (cost table) vs report.txt
rows = {}
for l in rep.splitlines():
    m = re.match(r"\| (pw-A|pw-B2|pw-B|ab-full-A|ab-c-A|ab-i-A|ab-i-B|ab-batch) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+)% \| (\d+) \| (\d+)% \|", l)
    if m:
        rows[m.group(1)] = [int(x) for x in m.groups()[1:]]
chk("report.txt has 8 cost rows", len(rows) == 8, str(list(rows)))
sec3 = doc.split("## 3. A tarefa canônica")[1].split("## 4.")[0]
cell = B + r"([\d.]+)" + B
drows = []
for l in sec3.splitlines():
    m = re.match(r"\| (.+?) \| " + cell + " \\| " + cell + " \\| " + cell + " \\| " + cell + " \\| " + B + r"(\d+)%" + B + " \\| " + cell + " \\| " + B + r"(\d+)%" + B + " \\|", l)
    if m:
        v = m.groups()
        drows.append((v[0].replace("*", ""), [num(v[1]), num(v[2]), num(v[3]), num(v[4]), int(v[5]), num(v[6]), int(v[7])]))
order = ["pw-A", "pw-B", "pw-B2", "ab-full-A", "ab-c-A", "ab-i-A", "ab-i-B", "ab-batch"]
chk("doc section 3 has 8 rows", len(drows) == 8, str(len(drows)))
for (label, v), cfg in zip(drows, order):
    r = rows[cfg]  # calls, results, callsTok, ctxAdded, ite30, ite30static, pct, ite200, pct200
    exp = [r[0], r[1], r[3], r[5], r[6], r[7], r[8]]
    chk(f"sec3 {cfg} <- '{label}'", v == exp, f"doc={v} data={exp}")

# ---- headline percentages (Em 8 linhas, section 3 bullets)
pwA30, pwA200 = rows["pw-A"][5], rows["pw-A"][7]
pwB2_30, pwB2_200 = rows["pw-B2"][5], rows["pw-B2"][7]
b30, b200 = rows["ab-batch"][5], rows["ab-batch"][7]
ib200, pwB200 = rows["ab-i-B"][7], rows["pw-B"][7]
chk("batch = 28% / 38% of pw-A", round(100 * b30 / pwA30) == 28 and round(100 * b200 / pwA200) == 38, f"{100*b30/pwA30:.1f}/{100*b200/pwA200:.1f}")
chk("batch vs pw-B2: -37% / -43% (63% / 57%)", round(100 * (1 - b30 / pwB2_30)) == 37 and round(100 * (1 - b200 / pwB2_200)) == 43 and round(100 * b30 / pwB2_30) == 63 and round(100 * b200 / pwB2_200) == 57, f"{100*b30/pwB2_30:.1f}/{100*b200/pwB2_200:.1f}")
chk("ab-i-B @200k = 104% of pw-A and 142% of pw-B", round(100 * ib200 / pwA200) == 104 and round(100 * ib200 / pwB200) == 142, f"{100*ib200/pwA200:.1f}/{100*ib200/pwB200:.1f}")
chk("batch is 4 calls, pw-B2 is 8, ab one-command-per-call is 13", rows["ab-batch"][0] == 4 and rows["pw-B2"][0] == 8 and rows["ab-i-B"][0] == 13)
noStaticBatch = float(re.search(r"\| ab-batch \| \d+ \| \d+ \| \d+ \| \d+ \| (\d+) \|", rep).group(1))
noStaticB2 = float(re.search(r"\| pw-B2 \| \d+ \| \d+ \| \d+ \| \d+ \| (\d+) \|", rep).group(1))
chk("without static, batch is 46% below pw-B2 at B=30k", round(100 * (1 - noStaticBatch / noStaticB2)) == 46, f"{100*(1-noStaticBatch/noStaticB2):.1f}")

# ---- section 2 (snapshot table) vs micro.json
sec2 = doc.split("## 2. Tokens por observação")[1].split("## 3.")[0]
keys = ["pw snapshot", "pw snapshot depth=3", "pw find controls", "ab snapshot", "ab -i", "ab -c", "ab -d 3"]
pages = ["login", "form", "todo", "dashboard", "heavy"]
got = []
for l in sec2.splitlines():
    m = re.match(r"\| (login|formulário|lista 40 linhas|lista HN|Wikipédia)[^|]* \|" + (" " + cell + " \\|") * 7, l)
    if m:
        got.append([num(x) for x in m.groups()[1:]])
chk("doc section 2 has 5 rows", len(got) == 5, str(len(got)))
for g, p in zip(got, pages):
    exp = [micro["pages"][p][k] for k in keys]
    chk(f"sec2 {p}", g == exp, f"doc={g} data={exp}")
red = [round(100 * (1 - micro["pages"][p]["ab -i"] / micro["pages"][p]["pw snapshot"])) for p in pages]
chk("-i reductions are -68/-64/-72/-66/-73", red == [68, 64, 72, 66, 73], str(red))
full = [round(100 * (1 - micro["pages"][p]["ab snapshot"] / micro["pages"][p]["pw snapshot"])) for p in pages]
chk("ab full snapshot reductions span ~0..49%", min(full) >= -1 and max(full) == 49, str(full))

# ---- section 5 (RAM) from the task jsons; MB = KB/1024
def mb(c, k, f):
    return json.load(open(f"{D}/results/task-{c}.json"))["mem"][k][f] / 1024

pw = [mb(c, "afterInit", "rssKB") for c in ("pw-A", "pw-B", "pw-B2")]
pw1 = [mb(c, "afterFirstSnapshot", "rssKB") for c in ("pw-A", "pw-B", "pw-B2")]
pwe = [mb(c, "afterTask", "rssKB") for c in ("pw-A", "pw-B", "pw-B2")]
pwp0 = [mb(c, "afterInit", "pssKB") for c in ("pw-A", "pw-B", "pw-B2")]
pwpe = [mb(c, "afterTask", "pssKB") for c in ("pw-A", "pw-B", "pw-B2")]
chk("PW direct RSS init 117-119", round(min(pw)) == 117 and round(max(pw)) == 119, str([round(x, 1) for x in pw]))
chk("PW direct RSS 1st snapshot 128-130", round(min(pw1)) == 128 and round(max(pw1)) == 130, str([round(x, 1) for x in pw1]))
chk("PW direct RSS end 139-140", round(min(pwe)) == 139 and round(max(pwe)) == 140, str([round(x, 1) for x in pwe]))
def tight(lo, hi, xs):  # the quoted range must contain every measured value with < 1 MB of slack on each side
    return lo <= min(xs) and max(xs) <= hi and (min(xs) - lo) < 1 and (hi - max(xs)) < 1
chk("PW direct PSS 92-94 -> 113-115 (contains all values, < 1 MB slack)", tight(92, 94, pwp0) and tight(113, 115, pwpe), f"{[round(x,1) for x in pwp0]} {[round(x,1) for x in pwpe]}")
n = json.load(open(D + "/results/task-pw-npx.json"))["mem"]
chk("PW npx RSS 192 -> 204 with 3 procs", round(n["afterInit"]["rssKB"] / 1024) == 192 and round(n["afterFirstSnapshot"]["rssKB"] / 1024) == 204 and n["afterInit"]["procs"] == 3)
chk("PW npx PSS 132 -> 143", round(n["afterInit"]["pssKB"] / 1024) == 132 and round(n["afterFirstSnapshot"]["pssKB"] / 1024) == 143)
rowsnpx = {r["cmd"].split()[0] + " " + r["cmd"].split()[1]: round(r["rss"] / 1024) for r in n["afterFirstSnapshot"]["rows"]}
chk("npx tree: npm exec 76 / sh 2 / node 126", sorted(round(r["rss"] / 1024) for r in n["afterFirstSnapshot"]["rows"]) == [2, 76, 126], str(rowsnpx))
abB = [mb(c, "afterTask", "rssKB") for c in ("ab-i-B", "ab-batch")]
abA = [mb(c, "afterTask", "rssKB") for c in ("ab-i-A", "ab-full-A", "ab-c-A")]
ab1 = [mb(c, "afterFirstSnapshot", "rssKB") for c in ("ab-i-B", "ab-i-A", "ab-full-A", "ab-c-A")]
chk("AB daemon 1st snapshot ~11 MB", all(10.5 <= x < 11.9 for x in ab1), str([round(x, 1) for x in ab1]))
chk("AB daemon end (B/batch) ~12 MB", all(11.5 <= x < 12.5 for x in abB), str([round(x, 1) for x in abB]))
chk("AB daemon end (A) 21-23 MB", round(min(abA)) == 21 and round(max(abA)) == 23, str([round(x, 1) for x in abA]))
chk("ratios: direct/AB ~11x, npx/AB ~16x, worst-case ~6x", 10.5 <= (sum(pwe) / 3) / (sum(abB) / 2) <= 12.5 and 15 <= (n["afterFirstSnapshot"]["rssKB"] / 1024) / (sum(abB) / 2) <= 18 and 5.5 <= (sum(pwe) / 3) / max(abA) <= 6.6,
    f"{(sum(pwe)/3)/(sum(abB)/2):.1f}/{(n['afterFirstSnapshot']['rssKB']/1024)/(sum(abB)/2):.1f}/{(sum(pwe)/3)/max(abA):.1f}")

# ---- section 7 (static) vs saved evidence
st = (open(D + "/results/probe-tools.txt").read() + open(D + "/results/static-sizes.txt").read()).replace(" B", "")
for needle in ("17616", "3764", "79991", "16851", "417365", "87943", "39038", "8571", "28109", "6065", "35705", "7926", "7557", "2046"):
    chk("static number " + needle + " present in saved evidence", needle in st)
chk("tool counts 25 / 29 / 156", all(f'"tools": {c}' in st for c in (25, 29, 156)))

# ---- section 4 (delta) vs micro.json / delta2.json / compact-hides-text.txt
mt, mh = micro["delta"]["todo"], micro["delta"]["heavy"]
d2 = json.load(open(D + "/results/delta2.json"))
chk("todo: -i full again ~500 (490-520)", all(490 <= x <= 520 for x in mt["ab_i_full_each"]), str(mt["ab_i_full_each"]))
chk("todo: -i --delta = 80 on every click", mt["ab_i_delta"] == [80, 80, 80], str(mt["ab_i_delta"]))
chk("todo: pw snapshot ~1.700 (1677-1709)", min(mt["pw_snapshot_each"]) == 1677 and max(mt["pw_snapshot_each"]) == 1709, str(mt["pw_snapshot_each"]))
chk("todo: pw find 138-161", min(mt["pw_find_verify"]) == 138 and max(mt["pw_find_verify"]) == 161, str(mt["pw_find_verify"]))
chk("heavy: -i --delta = unchanged, 7 tokens", mh["ab_i_delta"] == [7], str(mh["ab_i_delta"]))
chk("heavy: pw snapshot after the click = 70.808", mh["pw_snapshot_each"] == [70808], str(mh["pw_snapshot_each"]))
h, hc = d2["heavy snapshot --delta"], d2["heavy snapshot -c --delta"]
chk("heavy --delta: baseline 39508, deltas 94/2236/94, all see the note", h["baselineTok"] == 39508 and [d["tok"] for d in h["deltas"]] == [94, 2236, 94] and all(d["sawNewText"] for d in h["deltas"]))
chk("heavy -c --delta: deltas 7/58/7, never see the note", [d["tok"] for d in hc["deltas"]] == [7, 58, 7] and not any(d["sawNewText"] for d in hc["deltas"]))
nav = lambda c: json.load(open(f"{D}/results/task-{c}.json"))["respTok"]
chk("navigating flow: -i --delta == -i == 5135", nav("ab-delta-A") == nav("ab-i-A") == 5135)
ch = open(D + "/results/compact-hides-text.txt").read()
chk("compact-hides-text: DOM truth = 1 note", "#notes li count = 1" in ch)
chk("compact-hides-text: full snapshot sees it (1)", re.search(r"snapshot \(full\)\s*: 1\b", ch) is not None)
chk("compact-hides-text: -c, -i and -i -c do not (0)", all(re.search(p + r"\s*: 0\b", ch) for p in (r"snapshot -c", r"snapshot -i", r"snapshot -i -c")))
sc = open(D + "/results/strace-connect.txt").read()
chk("strace: only loopback CDP + unix socket, 0 non-loopback connects", "non-loopback connects: 0" in sc and "EXTERNAL" not in sc and "AF_INET 127.0.0.1:47222" in sc and "AF_UNIX" in sc)
# ---- section 6 (shared Chrome) vs the saved logs
shr = open(D + "/results/share-test.txt").read()
pn = open(D + "/results/pin-test.txt").read()
chk("PW x2: PW1 sees TAB-B1 (PW2's page), same single tab", "PW1 snapshot sees: TAB-B1 | PW2 sees: TAB-B1" in shr and re.search(r'PW2 navigate /tab/B1 -> tabs \["\w+:/tab/B1"\]', shr) is not None)
chk("PW x2: after PW2 re-navigates PW1 sees TAB-B2", "after PW2 navigates again: PW1 sees: TAB-B2" in shr)
chk("AB without --pin-tab: both sessions see TAB-B1", "s1 get title: TAB-B1 | s2 get title: TAB-B1" in shr)
m = re.search(r"tabs now \[(.*?)\]", pn)
chk("pin: three tabs (blank kept + A1 + B1)", m is not None and all(x in m.group(1) for x in ("about:blank", "/tab/A1", "/tab/B1")), str(m and m.group(1)))
chk("pin: a stays on A1 while b goes to B2", re.search(r"after \w+ re-open:\s+\w+ title: TAB-A1 \| \w+ title: TAB-B2", pn) is not None)
chk("pin: tab_locked when b takes a's tab", re.search(r"tries to take \w+ tab -> \[exit 1\] ✗ tab_locked", pn) is not None)
chk("pin: a human tab steals nothing", re.search(r"human opens a tab -> tabs \[.*HUMAN.*\] \| \w+ title: TAB-A1 \| \w+ title: TAB-B2", pn) is not None)
chk("pin: tab_gone on get title and on eval; b unaffected; recover via tab new", re.search(r"closed externally; get title -> \[exit 1\] ✗ tab_gone", pn) and re.search(r"\(eval\) -> \[exit 1\] ✗ tab_gone", pn) and "unaffected -> TAB-B2" in pn and re.search(r"recover with tab new -> .*\| \w+ title: TAB-A2", pn))
mm = re.search(r"after both close -> tabs \[(.*?)\] \| chrome alive: true", pn)
chk("pin: tabs REMAIN after close, Chrome alive", mm is not None and "/tab/A2" in mm.group(1) and "/tab/B2" in mm.group(1), str(mm and mm.group(1)))

print("\nALL OK" if ok else "\nSOME CHECK FAILED")
sys.exit(0 if ok else 1)
