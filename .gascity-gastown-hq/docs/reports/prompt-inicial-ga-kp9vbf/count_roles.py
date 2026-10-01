"""Exact token count of each role's rendered prime: total_in(prime as system prompt) - total_in(baseline), same harness as cache_probe.py."""
import json, os, subprocess, sys, time

SP = os.path.dirname(os.path.abspath(__file__))
CWD = os.path.join(SP, "probe_cwd")
BASE = 2602   # P0 baseline total_in measured with this harness (input+cache_creation+cache_read)


def total_in(sysfile):
    cmd = ["claude", "-p", "--output-format", "json", "--model", "sonnet", "--tools", "", "--strict-mcp-config",
           "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "project",
           "--append-system-prompt-file", sysfile]
    r = subprocess.run(cmd, input="Responda apenas: OK", capture_output=True, text=True, cwd=CWD, timeout=600)
    u = json.loads(r.stdout)["usage"]
    return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


out = {}
for role in sys.argv[1:]:
    f = os.path.join(SP, "primes", role + ".md")
    txt = open(f).read()
    t = total_in(f)
    d = t - BASE
    out[role] = dict(chars=len(txt), bytes=len(txt.encode()), tokens=d, chars_per_token=round(len(txt) / d, 3), bytes_per_token=round(len(txt.encode()) / d, 3))
    print(role, json.dumps(out[role])); sys.stdout.flush()
json.dump(out, open(os.path.join(SP, "role_tokens.json"), "w"), indent=1)
