"""Does the skill fire when the procedure it documents is run? (caveat: the doctrine section is still in the prompt, so this is NOT a test
of a skill-only world — it only shows a skill description is a probabilistic trigger.)"""
import json


def rate(fired, need):
    # no session needed the procedure = no sample, not 0%
    return "sem amostra" if not need else f"{100 * len(fired) / len(need):.0f}%"


d = json.load(open("sessions.json"))
W = [x for x in d if x["role"] == "wa-worker"]
need = [x for x in W if x["proc"].get("s3_mockup")]       # detector is loose: matches the word "mockup" in any command
fired = [x for x in need if x["skills"].get("wa-worker-session-protocol")]
anyfire = [x for x in W if x["skills"].get("wa-worker-session-protocol")]
print(f"wa-worker sessions: {len(W)}")
print(f"  ran S3/mockup commands (need): {len(need)}")
print(f"  of those, invoked skill wa-worker-session-protocol: {len(fired)}  ({rate(fired, need)})")
print(f"  invoked the skill at all: {len(anyfire)}  (so {len(anyfire) - len(fired)} fired without S3 commands)")
G = [x for x in d if x["role"] == "dog"]
need = [x for x in G if x["proc"].get("gate_done")]
fired = [x for x in need if x["skills"].get("gate-done")]
print(f"dog sessions: {len(G)}; ran gate-done/ready-for-gate commands: {len(need)}; invoked skill gate-done: {len(fired)} ({rate(fired, need)})")
