"""Exact token count of each role's rendered prime: total_in(prime as system prompt) - total_in(no prime), same harness as cache_probe.py.

Costs real tokens (~320 mil for the 8 roles). The baseline is measured on EVERY run (one extra ~2,6 mil-token call) so a harness change
cannot shift every role by a stale constant. A role whose prime file is missing or empty (suspended agent) is reported and left out — it is
never counted as 0 tokens. role_tokens.json is MERGED with what is already there, so re-running one role does not erase the others.
"""
import json, os, subprocess, sys

SP = os.path.dirname(os.path.abspath(__file__))
CWD = os.path.join(SP, "probe_cwd")
os.makedirs(os.path.join(CWD, ".claude"), exist_ok=True)
OUT = os.path.join(SP, "role_tokens.json")


def total_in(sysfile=None):
    cmd = ["claude", "-p", "--output-format", "json", "--model", "sonnet", "--tools", "", "--strict-mcp-config",
           "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "project"]
    if sysfile:
        cmd += ["--append-system-prompt-file", sysfile]
    r = subprocess.run(cmd, input="Responda apenas: OK", capture_output=True, text=True, cwd=CWD, timeout=600)
    try:
        u = json.loads(r.stdout)["usage"]
    except Exception as e:                       # a failed call must stop the count, not become a token number
        raise SystemExit(f"claude -p failed (rc={r.returncode}) for {sysfile or 'baseline'}: {e}; stdout[:200]={r.stdout[:200]!r} stderr[:200]={r.stderr[:200]!r}")
    return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


roles = sys.argv[1:]
if not roles:
    raise SystemExit("usage: count_roles.py <role> [<role> ...]   (reads primes/<role>.md, see render_primes.sh)")
base = total_in()
print(f"baseline (no prime): {base} tokens")
out = json.load(open(OUT)) if os.path.exists(OUT) else {}
for role in roles:
    f = os.path.join(SP, "primes", role + ".md")
    txt = open(f).read() if os.path.isfile(f) else ""
    if not txt.strip():
        print(f"{role}: SKIPPED — primes/{role}.md is missing or empty (suspended agent or render failed); NOT counted as 0 tokens")
        continue
    d = total_in(f) - base
    if d <= 0:
        print(f"{role}: SKIPPED — measured delta {d} is not positive; the call did not carry the prime")
        continue
    out[role] = dict(chars=len(txt), bytes=len(txt.encode()), tokens=d, chars_per_token=round(len(txt) / d, 3),
                     bytes_per_token=round(len(txt.encode()) / d, 3), baseline=base)
    print(role, json.dumps(out[role]))
    sys.stdout.flush()
json.dump(out, open(OUT, "w"), indent=1)
