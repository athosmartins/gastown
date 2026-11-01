#!/usr/bin/env python3
"""nudge-stranded-census — ga-9uv1xps (loose end 1: PENDING nudges fenced to a session that is gone).

READ-ONLY. It changes nothing: not the queue, not a bead. It classifies every PENDING nudge by
  (fence state)  x  (message class)
and says out loud the one combination that would mean information is about to be lost.

Why a census and not a fix (measured 2026-11-01, 49 pending): 46 were fenced to a session whose bead is
closed (the ad-hoc gate-review / worker / dog sessions end in minutes; the nudge outlives them by up to
the 24 h TTL). All 46 were work pointers whose durable record is a BEAD (a gate-review task has its own
gate-run bead, "Bead nova para voce" / GATE-FEEDBACK / "has passed gate" point at one, DISK CRITICAL is
stale in minutes). The ad-hoc reviewers have agent == session, so there is no "successor session" to
re-fence to, and nudge-queue-hygiene.py keeps a deliberate invariant: it never touches non-warning
items. So the rule is: DO NOT re-fence/move/delete a stranded non-warning item; the engine's 24 h TTL is
its garbage collector. That rule is only safe while the stranded items stay pointers. This census watches
exactly that assumption.

fence state (read from the session BEAD, never from `gc session list`, which has no closed sessions):
  viva       the session bead exists and is not closed
  encerrada  the session bead exists and is closed
  nao-sei    no bead row for that id / bd failed / unreadable      <- NEVER folded into encerrada
message class (closed allowlist of the shapes measured on the live queue; anything else is `outro`):
  tarefa-gate | ponteiro-bead | aviso-transit | outro

ALARM (STRANDED-INFO, rc 1): class `outro` AND fence `encerrada` AND less than --alarm-hours (6) of TTL
left (expires_at). That is an item of a shape nobody has seen, addressed to a session that is gone, about to
expire: its text may be the only copy. When this fires the rule above must be reconsidered, not silenced.
Items in `outro` with a live or unknown fence are only counted. An `outro` item whose expires_at cannot be
read is counted as `outro_ttl_unreadable` and does NOT alarm (inert), but is listed in the summary.

rc: 0 nothing to flag, 1 STRANDED-INFO, 2 cannot tell (state unreadable / bd unusable for every fence).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

BATCH = 20
ALARM_HOURS_DEFAULT = 6.0

# Measured on the live queue 2026-11-01 (see header). Extend only with a shape that was MEASURED to point at a bead.
TAREFA = re.compile(r"QUALITY GATE REVIEW", re.I)
TRANSIT = re.compile(r"DISK CRITICAL|DISK LOW|disk .*floor", re.I)
PONTEIRO = re.compile(
    r"Bead nova para voc|GATE-FEEDBACK|has passed gate|Gate FAILED|QUALITY GATE FAILED|Your branch|blocker .* closed",
    re.I)


def classify(message):
    if not isinstance(message, str):
        return "outro"                      # message ilegível -> não é uma forma conhecida: conta como outro
    if TAREFA.search(message):
        return "tarefa-gate"
    if TRANSIT.search(message):
        return "aviso-transit"
    if PONTEIRO.search(message):
        return "ponteiro-bead"
    return "outro"


def parse_ts(text):
    """RFC3339 (with or without fractional seconds, Z or offset) -> aware datetime; None when unreadable."""
    if not isinstance(text, str) or not text:
        return None
    t = text.strip()
    t = re.sub(r"\.(\d{1,9})", lambda m: "." + m.group(1).ljust(6, "0")[:6], t)
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(t)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def run_bd_show(bd_cmd, ids, cwd):
    """List of rows, or None when the call failed / was unreadable (the caller decides what None means)."""
    try:
        res = subprocess.run(bd_cmd + ["show", *ids, "--json"], capture_output=True, text=True, timeout=120, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    try:
        doc = json.loads(res.stdout)
    except ValueError:
        return None
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list):
        return None
    return [r for r in doc if isinstance(r, dict) and r.get("id")]


def resolve_fences(bd_cmd, fences, cwd):
    """fence id -> 'viva' | 'encerrada' | 'nao-sei'. Returns (states, bd_ok) where bd_ok is False when NO fence
    could be resolved at all (bd unusable: the run cannot tell, rc 2)."""
    rows = {}
    for i in range(0, len(fences), BATCH):
        batch = fences[i:i + BATCH]
        got = run_bd_show(bd_cmd, batch, cwd)
        if got is None:
            # um id sumido (bead expurgado) derruba o lote inteiro no bd: refaz um a um; o que não responder fica nao-sei
            got = []
            for one in batch:
                got.extend(run_bd_show(bd_cmd, [one], cwd) or [])
        for row in got:
            rows[row["id"]] = row
    states = {}
    for f in fences:
        row = rows.get(f)
        if row is None:
            states[f] = "nao-sei"
        elif row.get("status") == "closed":
            states[f] = "encerrada"
        elif isinstance(row.get("status"), str) and row.get("status"):
            states[f] = "viva"
        else:
            states[f] = "nao-sei"           # linha sem status legível -> não afirma vivo nem encerrado
    return states, (not fences or any(v != "nao-sei" for v in states.values()))


def append_log(path, summary):
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(summary, sort_keys=True) + "\n")
    except OSError as exc:
        print(f"WARN: could not append to log {path}: {exc}", file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.getcwd())
    ap.add_argument("--state", help="queue state file (default <city>/.gc/nudges/state.json)")
    ap.add_argument("--bd-cmd", default="gc bd", help="how to call bd (default 'gc bd'; selftests inject a fake)")
    ap.add_argument("--alarm-hours", type=float, default=ALARM_HOURS_DEFAULT)
    ap.add_argument("--now", help="RFC3339 'now' (tests)")
    ap.add_argument("--log", help="append the run summary (json line) here")
    args = ap.parse_args(argv)

    now = parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
    summary = {"ts": now.isoformat(timespec="seconds") if now else None}

    def finish(rc, **extra):
        summary.update(extra)
        summary["rc"] = rc
        append_log(args.log, summary)
        print(json.dumps(summary, sort_keys=True))
        return rc

    if now is None:
        return finish(2, error="--now unreadable")
    state_path = args.state or os.path.join(args.city, ".gc", "nudges", "state.json")
    # vazio -> sem itens pending: nada a contar (rc 0); falhou/ilegível/forma estranha -> rc 2, nada afirmado
    try:
        with open(state_path, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError) as exc:
        return finish(2, error=f"cannot read queue state {state_path}: {exc}")
    if not isinstance(state, dict):
        return finish(2, error="queue state is not an object")
    pending = state.get("pending")
    if pending is None:
        pending = []
    if not isinstance(pending, list):
        return finish(2, error="queue state 'pending' is not a list")

    items = [it for it in pending if isinstance(it, dict)]
    unreadable_items = len(pending) - len(items)
    fences = sorted({it.get("session_id") for it in items if isinstance(it.get("session_id"), str) and it.get("session_id")})
    bd_cmd = args.bd_cmd.split()
    fence_state, bd_ok = resolve_fences(bd_cmd, fences, args.city)
    if not bd_ok:
        return finish(2, error="bd resolved none of the %d fences: cannot tell open from closed" % len(fences),
                      pending=len(pending))

    matrix, alarms = {}, []
    outro_ttl_unreadable = []
    for it in items:
        sid = it.get("session_id")
        fs = fence_state.get(sid, "sem-fence") if isinstance(sid, str) and sid else "sem-fence"
        cls = classify(it.get("message"))
        matrix["%s|%s" % (fs, cls)] = matrix.get("%s|%s" % (fs, cls), 0) + 1
        if cls == "outro" and fs == "encerrada":
            exp = parse_ts(it.get("expires_at"))
            if exp is None:
                outro_ttl_unreadable.append(it.get("id"))
            elif (exp - now).total_seconds() < args.alarm_hours * 3600:
                alarms.append({"id": it.get("id"), "agent": it.get("agent"), "fence": sid,
                               "expires_at": it.get("expires_at"),
                               "message_head": (it.get("message") or "")[:160] if isinstance(it.get("message"), str) else None})

    extra = dict(pending=len(pending), unreadable_items=unreadable_items, fences=len(fences),
                 fences_nao_sei=sum(1 for v in fence_state.values() if v == "nao-sei"),
                 matrix=matrix, outro_ttl_unreadable=outro_ttl_unreadable, alarms=alarms)
    if alarms:
        for a in alarms:
            print("STRANDED-INFO item=%s agent=%s fence=%s expires_at=%s | %s" %
                  (a["id"], a["agent"], a["fence"], a["expires_at"], a["message_head"]))
        return finish(1, **extra)
    return finish(0, **extra)


if __name__ == "__main__":
    sys.exit(main())
