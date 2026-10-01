"""cache_probe.py (ga-kp9vbf): does the position of the per-session beacon decide whether the doctrine is a cross-session cache READ?

Same harness for every call: claude -p, sonnet, no tools, project-only settings, scratch cwd. The doctrine D is the real dog prime.
  P0  baseline (no doctrine)                             -> B = tokens of the harness itself
  P1  beacon-A + D                                       -> today's layout; D tokens = total(P1) - total(P0)
  P2  beacon-B + D   (same D, different beacon)          -> does D come back as cache_read?  (predicted: NO, only the static prefix)
  P3  D + beacon-C                                       -> doctrine first (different prefix than P1/P2, so it is written)
  P4  D + beacon-D   (same D, different trailing beacon) -> predicted: D comes back as cache_read
"""
import json, os, subprocess, sys, time

SP = os.path.dirname(os.path.abspath(__file__))
D = open(os.path.join(SP, "primes", "dog.md")).read()
CWD = os.path.join(SP, "probe_cwd"); os.makedirs(os.path.join(CWD, ".claude"), exist_ok=True)
ASK = "Responda apenas: OK"


def run(label, prompt, sysfile=None):
    cmd = ["claude", "-p", "--output-format", "json", "--model", "sonnet", "--tools", "", "--strict-mcp-config",
           "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "project"]
    if sysfile:
        cmd += ["--append-system-prompt-file", sysfile]
    t0 = time.time()
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd=CWD, timeout=600)
    try:
        j = json.loads(r.stdout)
    except Exception:
        print(label, "FAILED rc=", r.returncode, r.stdout[:300], r.stderr[:300]); return None
    u = j.get("usage") or {}
    cc = u.get("cache_creation") or {}
    row = dict(label=label, input=u.get("input_tokens"), cache_creation=u.get("cache_creation_input_tokens"),
               cache_read=u.get("cache_read_input_tokens"), c1h=cc.get("ephemeral_1h_input_tokens"), c5m=cc.get("ephemeral_5m_input_tokens"),
               output=u.get("output_tokens"), secs=round(time.time() - t0, 1), result=str(j.get("result"))[:30])
    row["total_in"] = sum(int(row[k] or 0) for k in ("input", "cache_creation", "cache_read"))
    print(json.dumps(row)); sys.stdout.flush()
    return row


stamp = lambda s: f"[gascity] probe-{s} • {time.strftime('%Y-%m-%dT%H:%M:%S')}"
which = sys.argv[1:] or ["P0", "P1", "P2", "P3", "P4"]
for w in which:
    if w == "P0": run("P0 baseline", ASK)
    if w == "P1": run("P1 beacon-A + D", stamp("A") + "\n\n" + D + "\n\n" + ASK)
    if w == "P2": run("P2 beacon-B + D", stamp("B") + "\n\n" + D + "\n\n" + ASK)
    if w == "P3": run("P3 D + beacon-C", D + "\n\n" + stamp("C") + "\n" + ASK)
    if w == "P4": run("P4 D + beacon-D", D + "\n\n" + stamp("D") + "\n" + ASK)

SYS = os.path.join(SP, "sys_D.txt"); open(SYS, "w").write(D)
SYS2 = os.path.join(SP, "sys_D_instance.txt")
# same doctrine but with a per-instance string in the LAST line (what gc renders today: alias / work dir / mail identity)
open(SYS2, "w").write(D + "\nMail identity: dog/gastown.dog-7\n")
for w in which:
    if w == "P5": run("P5 sys=D, beacon-E", stamp("E") + "\n" + ASK, SYS)
    if w == "P6": run("P6 sys=D, beacon-F", stamp("F") + "\n" + ASK, SYS)
    if w == "P7": run("P7 sys=D+instance-tail, beacon-G", stamp("G") + "\n" + ASK, SYS2)
    if w == "P8": run("P8 sys=D+instance-tail(dog-8), beacon-H", stamp("H") + "\n" + ASK, SYS2.replace("dog-7", "dog-8") if False else SYS2)
