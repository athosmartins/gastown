import json
d = json.load(open("sessions.json"))
W = [x for x in d if x["role"] == "wa-worker"]
need = [x for x in W if x["proc"].get("s3_mockup")]
fired = [x for x in need if x["skills"].get("wa-worker-session-protocol")]
anyfire = [x for x in W if x["skills"].get("wa-worker-session-protocol")]
print(f"wa-worker sessions: {len(W)}")
print(f"  ran S3/mockup commands (need): {len(need)}")
print(f"  of those, invoked skill wa-worker-session-protocol: {len(fired)}  ({100*len(fired)/max(1,len(need)):.0f}%)")
print(f"  invoked the skill at all: {len(anyfire)}  (so {len(anyfire)-len(fired)} fired without S3 commands)")
G = [x for x in d if x["role"] == "dog"]
need = [x for x in G if x["proc"].get("gate_done")]
fired = [x for x in need if x["skills"].get("gate-done")]
print(f"dog sessions: {len(G)}; ran gate-done/ready-for-gate commands: {len(need)}; invoked skill gate-done: {len(fired)} ({100*len(fired)/max(1,len(need)):.0f}%)")
