#!/usr/bin/env python3
"""nudge-stranded-census — ga-9uv1xps (loose end 1: PENDING nudges fenced to a session that is gone). See docs/nudge-stranded-census.md.

It never writes the nudge queue or a bead. It classifies every PENDING nudge by (fence state) x (message class) and says out
loud the combinations that mean information is about to be lost, or that it cannot rule out. "Out loud" is `notify` with
--notify (the order's mode); without it the census only prints, so a hand run pings nobody and writes nothing. With --notify
it also keeps a ledger of its own in --state-dir and appends its summary to --log.

The rule it watches (measured 2026-11-01, 50 pending): 46 were fenced to a session whose bead is closed, and all 46 were
pointers to a bead, which holds the durable record. Nothing can be re-fenced (the ad-hoc reviewers have agent == session) and
nudge-queue-hygiene.py never touches non-warning items, so a stranded item is left to the engine's 24 h TTL. That is only
safe while stranded items stay pointers.

fence state (read from the session BEAD; `gc session list` has no closed sessions):
  viva       the bead exists and its status is not `closed` (quality-gate-dispatcher reads it the same way)
  encerrada  the bead exists and its status is `closed`
  nao-sei    no row (purged), bd failed, no time left, or a row without a readable status: never folded into encerrada
message class (closed allowlist of the measured shapes; anything else is `outro`): tarefa-gate | ponteiro-bead | aviso-transit

Outcomes, never two: a census that says nothing must mean "looked, nothing there".
  ALARM        rc 1 (STRANDED-INFO): class `outro`, fence `encerrada`, under --alarm-hours (6) of TTL left; a zero or past
               expires_at counts as none left. Its text may be the only copy: reconsider the rule, do not silence the alarm.
  CANNOT TELL  rc 2: something that could be an ALARM was not decided. Whole run: the queue state is unreadable, odd or in a
               missing dir; bd resolved no fence (or the --deadline-s budget ran out); a crash. Per item, listed by id: an
               `outro` item with a closed fence and an unreadable expires_at (ttl-unreadable); an `outro` item under 6 h of
               TTL, or with an unreadable one, whose fence could not be resolved (fence-unreadable); a pending entry that is
               not an object (unreadable-items).
  CLEAN        rc 0: everything that could matter was decided and none is an alarm. A queue dir with no state.json, a 0-byte
               one and a JSON null are an empty queue (as the engine's LoadState and nudge-queue-hygiene read them).
  rc 3         --notify only: a notice was due and notify could not deliver it, or the ledger could not be written. Nothing is
               recorded as sent, so the next run tries again. An alarm and a cannot-tell in one run: rc 1, two notices.

Delivery. The exit code alone reaches nobody: order-exec-failure-watchdog.sh alerts only when an order has a NEW `failed: exit
status N` line in 2 CONSECUTIVE 5-min sweeps and resets at the first sweep without one, and this order runs once per 3 h. So
the census notifies itself, as nudge-stranded-detector.py does (ntfy: ASCII text, ids but never the nudge text, which may hold
anything): an ALARM once per nudge id while it stays pending, CANNOT TELL once per --cannot-tell-cooldown-min per reason-set.

Cost: one queue read plus ceil(fences / 20) `bd show` calls (a batch with a purged id is re-asked id by id), bounded by
--deadline-s; the order's `timeout` also covers two notify calls. Every summary line has `duration_s`: read the live cost there.
"""
import argparse
import contextlib
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time

BATCH = 20
ALARM_HOURS_DEFAULT = 6.0
DEADLINE_S_DEFAULT = 150.0              # the bd phase; the order's timeout (240 s) also covers two notify calls after it
BD_CALL_TIMEOUT_S = 60.0
NOTIFY_TIMEOUT_S = 30.0
CANNOT_TELL_COOLDOWN_MIN_DEFAULT = 300.0   # below 2 x the 3 h cadence: every second run says it again, whatever the jitter
IDS_IN_NOTICE = 8
LEDGER_NAME = "nudge-stranded-census-seen.json"

# Measured on the live queue 2026-11-01. Extend only with a shape that was MEASURED to point at a bead, and add its row to the
# selftest (A) and to the doc: a loosened pattern is the quiet direction, it hides an alarm.
# "Gate FAILED" is a case-insensitive substring match, so it also covers "QUALITY GATE FAILED for branch ...".
TAREFA = re.compile(r"QUALITY GATE REVIEW", re.I)
TRANSIT = re.compile(r"DISK CRITICAL|DISK LOW|disk .*floor", re.I)
PONTEIRO = re.compile(
    r"Bead nova para voc|GATE-FEEDBACK|has passed gate|Gate FAILED|Your branch|blocker .* closed",
    re.I)


class Undecided(Exception):
    """The whole run is blind. `key` names the reason (the notify cooldown is per reason-set), `text` says what failed."""

    def __init__(self, key, text):
        Exception.__init__(self, text)
        self.key, self.text = key, text


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


def read_state(path):
    """The engine's queue document as a dict ({} = an empty queue); Undecided for everything it cannot vouch for."""
    qdir = os.path.dirname(path) or "."
    # vazio -> {} (a queue dir with no state.json, 0 bytes, JSON null: the engine tags pending omitempty and LoadState reads the
    # first two as an empty queue, as nudge-queue-hygiene does); falhou/ilegível/forma estranha -> Undecided (rc 2), nothing asserted
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        if os.path.isdir(qdir):
            return {}
        raise Undecided("state-unreadable", "queue dir %s does not exist" % qdir)
    except (OSError, ValueError) as exc:
        raise Undecided("state-unreadable", "cannot read queue state %s: %s" % (path, exc))
    if len(raw) == 0:
        return {}
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise Undecided("state-unreadable", "cannot read queue state %s: %s" % (path, exc))
    if doc is None:
        return {}
    if not isinstance(doc, dict):
        raise Undecided("state-unreadable", "queue state is not an object")
    return doc


def run_bd_show(bd_cmd, ids, cwd, timeout):
    """List of rows, or None when the call failed / timed out / was unreadable (the caller decides what None means)."""
    try:
        res = subprocess.run(bd_cmd + ["show", *ids, "--json"], capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except (OSError, ValueError, subprocess.SubprocessError):      # ValueError: undecodable output, NUL in argv
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
    return [r for r in doc if isinstance(r, dict) and isinstance(r.get("id"), str) and r["id"]]


def resolve_fences(bd_cmd, fences, cwd, deadline):
    """fence id -> 'viva' | 'encerrada' | 'nao-sei'. Returns (states, bd_ok, deadline_hit). bd_ok is False when NO fence
    could be resolved at all (bd unusable: the run cannot tell, rc 2). deadline_hit is True when the time budget ran out
    before every call was made; the fences never asked are nao-sei, like any fence bd did not answer."""
    rows, hit = {}, [False]

    def ask(ids):
        left = deadline - time.monotonic()
        if left <= 0:
            hit[0] = True
            return None
        return run_bd_show(bd_cmd, ids, cwd, min(BD_CALL_TIMEOUT_S, left))

    for i in range(0, len(fences), BATCH):
        batch = fences[i:i + BATCH]
        got = ask(batch)
        if got is None:
            # um id sumido (bead expurgado) derruba o lote inteiro no bd: refaz um a um; o que não responder fica nao-sei
            got = []
            for one in batch:
                got.extend(ask([one]) or [])
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
    return states, (not fences or any(v != "nao-sei" for v in states.values())), hit[0]


def census(args, now, deadline, summary):
    """Reads the queue and the session beads. -> (alarms, blind, pending_ids): alarms is a list of dicts (STRANDED-INFO);
    blind maps reason -> list of strings (item ids, or one sentence for a whole-run reason) the census could not decide.
    Raises Undecided when it cannot even start deciding."""
    state_path = args.state or os.path.join(args.city, ".gc", "nudges", "state.json")
    pending = read_state(state_path).get("pending")
    if pending is None:                     # vazio (key absent or null: omitempty) -> []
        pending = []
    if not isinstance(pending, list):
        raise Undecided("state-unreadable", "queue state 'pending' is not a list")
    items, blind = [], {}
    for idx, it in enumerate(pending):
        if isinstance(it, dict):
            items.append(it)
        else:
            blind.setdefault("unreadable-items", []).append("item#%d" % idx)   # not an object: nothing of it can be classified
    fences = sorted({it.get("session_id") for it in items if isinstance(it.get("session_id"), str) and it.get("session_id")})
    fence_state, bd_ok, deadline_hit = resolve_fences(args.bd_cmd.split(), fences, args.city, deadline)
    summary.update(pending=len(pending), unreadable_items=len(pending) - len(items), fences=len(fences),
                   fences_nao_sei=sum(1 for v in fence_state.values() if v == "nao-sei"), deadline_hit=deadline_hit)
    if not bd_ok:
        raise Undecided("bd-unusable", "bd resolved none of the %d fences%s: cannot tell open from closed" %
                        (len(fences), " (time budget spent)" if deadline_hit else ""))

    matrix, alarms = {}, []
    ttl_unreadable, fence_unreadable = [], []
    for it in items:
        ident = str(it.get("id"))
        sid = it.get("session_id")
        fs = fence_state.get(sid, "sem-fence") if isinstance(sid, str) and sid else "sem-fence"
        cls = classify(it.get("message"))
        matrix["%s|%s" % (fs, cls)] = matrix.get("%s|%s" % (fs, cls), 0) + 1
        if cls != "outro" or fs not in ("encerrada", "nao-sei"):
            continue
        # vazio e ilegível expires_at → exp None, e None nunca é "longe": cai em ttl-unreadable (fence fechada) ou em
        # fence-unreadable (fence não resolvida), jamais no silêncio; lido → decide pela janela de --alarm-hours
        exp = parse_ts(it.get("expires_at"))
        soon = exp is None or (exp - now).total_seconds() < args.alarm_hours * 3600
        if fs == "nao-sei":
            if soon:
                fence_unreadable.append(ident)
        elif exp is None:
            ttl_unreadable.append(ident)
        elif soon:
            alarms.append({"id": it.get("id"), "agent": it.get("agent"), "fence": sid,
                           "expires_at": it.get("expires_at"),
                           "message_head": (it.get("message") or "")[:160] if isinstance(it.get("message"), str) else None})
    if ttl_unreadable:
        blind["ttl-unreadable"] = ttl_unreadable
    if fence_unreadable:
        blind["fence-unreadable"] = fence_unreadable
    summary.update(matrix=matrix, outro_ttl_unreadable=ttl_unreadable, outro_fence_unreadable=fence_unreadable, alarms=alarms)
    return alarms, blind, {str(it.get("id")) for it in items}


def warn(text):
    print("nudge-stranded-census: " + text, file=sys.stderr)


def append_log(path, summary):
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(summary, sort_keys=True) + "\n")
    except OSError as exc:
        warn("could not append to log %s: %s" % (path, exc))


def load_ledger(path):
    # vazio (no file) -> a fresh ledger; falhou/ilegível (unreadable, corrupt, wrong shape) -> a fresh ledger too, on purpose:
    # the cost is one repeated notice (loud, harmless), while refusing to notify would silence the census; the next write heals it
    fresh = {"alerted": {}, "cannot_tell": {}}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return fresh
    if not isinstance(doc, dict):
        return fresh
    alerted, cannot = doc.get("alerted"), doc.get("cannot_tell")
    return {"alerted": alerted if isinstance(alerted, dict) else {},
            "cannot_tell": cannot if isinstance(cannot, dict) else {}}


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ledger.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def tell(args, title, body, what, notices, kind):
    """notify. True only if it exited 0; a missing binary, a timeout or a non-zero exit is NOT delivered: loud (stderr and
    notices[kind] = failed), and the caller records nothing, so the next run tries again."""
    try:
        sent = subprocess.run([args.notify_bin, "-t", title, "-p", "3", body], capture_output=True, text=True,
                              timeout=NOTIFY_TIMEOUT_S).returncode == 0
    except (OSError, ValueError, subprocess.SubprocessError):
        sent = False
    notices[kind] = "sent" if sent else "failed"
    if not sent:
        warn("ALARM NOT DELIVERED (notify failed): " + what)
    return sent


def deliver(args, alarms, blind, pending_ids, summary, state_dir):
    """Tells a human about the ALARM and CANNOT TELL outcomes. -> True when something due could not be delivered or recorded
    (the run then ends rc 3). A notice is recorded in the ledger only after notify exited 0."""
    path = os.path.join(state_dir, LEDGER_NAME)
    ledger = load_ledger(path)
    changed, failed, notices = False, False, {}
    if pending_ids is not None:             # a blind run saw no queue: it must not forget what it already told
        for gone in [k for k in ledger["alerted"] if k not in pending_ids]:   # the ledger stays bounded by the queue itself
            del ledger["alerted"][gone]
            changed = True

    new = [a for a in alarms if str(a["id"]) not in ledger["alerted"]]
    if alarms:
        notices["stranded"] = "deduped"
    if new:
        lines = ["%s -> %s (fence %s) expira %s" % (a["id"], a["agent"] or "?", a["fence"], a["expires_at"])
                 for a in new[:IDS_IN_NOTICE]]
        if len(new) > IDS_IN_NOTICE:
            lines.append("... e mais %d" % (len(new) - IDS_IN_NOTICE))
        body = ("Nudge PENDENTE de forma desconhecida, fence em sessao ENCERRADA, expira em menos de %g h: o texto pode ser a "
                "unica copia. Releia a regra em docs/nudge-stranded-census.md (nao silencie o alarme). O texto esta no log "
                "do censo.\n%s" % (args.alarm_hours, "\n".join(lines)))
        if tell(args, "Censo de nudge preso: STRANDED-INFO (%d)" % len(new), body,
                "STRANDED-INFO for " + ",".join(str(a["id"]) for a in new), notices, "stranded"):
            for a in new:
                ledger["alerted"][str(a["id"])] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            summary["alarmed"] = [str(a["id"]) for a in new]
            changed = True
        else:
            failed = True

    if blind:
        key = ",".join(sorted(blind))
        # vazio (never told → 0) → fora da carência: avisa; ilegível (um carimbo que não é número) → elapsed None → avisa também;
        # carimbo no futuro (relógio andou para trás, arquivo corrompido) → avisa também: não é carência, só deixaria o censo mudo
        last, wall = ledger["cannot_tell"].get(key, 0), time.time()
        elapsed = wall - last if isinstance(last, (int, float)) else None
        if elapsed is not None and 0 <= elapsed < args.cannot_tell_cooldown_min * 60:
            notices["blind"] = "cooldown"
        else:
            lines = ["%s (%d): %s%s" % (reason, len(vals), ", ".join(v[:300] for v in vals[:IDS_IN_NOTICE]),
                                        "" if len(vals) <= IDS_IN_NOTICE else ", ...") for reason, vals in sorted(blind.items())]
            body = "O censo de nudge preso NAO consegue decidir: sem alarme aqui NAO significa limpo.\n" + "\n".join(lines)
            if tell(args, "Censo de nudge preso: cego", body, "the census is blind (%s)" % key, notices, "blind"):
                ledger["cannot_tell"][key] = int(wall)
                changed = True
            else:
                failed = True

    if changed:
        try:
            atomic_write(path, json.dumps(ledger, sort_keys=True))
        except OSError as exc:
            summary["ledger_write"] = "failed: %s" % exc     # the next run may repeat a notice: visible, not silent
            warn("could not write the ledger %s: %s" % (path, exc))
            failed = True
    if notices:
        summary["notices"] = notices
    return failed


def run(args):
    started = time.monotonic()
    deadline = started + args.deadline_s
    summary = {"deliver": bool(args.notify)}
    alarms, blind, pending_ids = [], {}, None
    now = parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
    summary["ts"] = now.isoformat(timespec="seconds") if now else None
    try:
        if now is None:
            raise Undecided("now-unreadable", "--now unreadable")
        alarms, blind, pending_ids = census(args, now, deadline, summary)
    except Undecided as exc:
        summary["error"] = exc.text
        blind = {exc.key: [exc.text]}
    except Exception as exc:     # a bug or a shape nobody foresaw: the run is BLIND — never a bare traceback, whose rc 1 reads as STRANDED-INFO
        summary["error"] = "census crashed: %s: %s" % (type(exc).__name__, exc)
        alarms, blind = [], {"crashed": [summary["error"]]}
    summary["cannot_tell"] = sum(len(v) for v in blind.values())
    summary["cannot_tell_reasons"] = {k: len(v) for k, v in sorted(blind.items())}
    rc = 1 if alarms else (2 if blind else 0)
    if args.notify:
        state_dir = args.state_dir or os.path.join(args.city, ".gc", "runtime", "packs", "town-deltas")
        try:
            if deliver(args, alarms, blind, pending_ids, summary, state_dir):
                rc = 3
        except Exception as exc:  # the delivery code may not end as a traceback either
            summary["deliver_error"] = "%s: %s" % (type(exc).__name__, exc)
            warn("delivery crashed: %s" % summary["deliver_error"])
            rc = 3
    summary["rc"] = rc
    summary["duration_s"] = round(time.monotonic() - started, 2)
    append_log(args.log, summary)         # before anything is printed: a print that fails must not cost the log line
    for a in alarms:
        print("STRANDED-INFO item=%s agent=%s fence=%s expires_at=%s | %s" %
              (a["id"], a["agent"], a["fence"], a["expires_at"], a["message_head"]))
    print(json.dumps(summary, sort_keys=True))
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.getcwd())
    ap.add_argument("--state", help="queue state file (default <city>/.gc/nudges/state.json)")
    ap.add_argument("--bd-cmd", default="gc bd", help="how to call bd (default 'gc bd'; selftests inject a fake)")
    ap.add_argument("--alarm-hours", type=float, default=ALARM_HOURS_DEFAULT)
    ap.add_argument("--deadline-s", type=float, default=DEADLINE_S_DEFAULT,
                    help="time budget of the bd phase, in seconds (default %g); fences not asked in time are nao-sei" % DEADLINE_S_DEFAULT)
    ap.add_argument("--notify", action="store_true",
                    help="deliver ALARM / CANNOT TELL through notify and keep the ledger in --state-dir (default: only print)")
    ap.add_argument("--notify-bin", default=os.environ.get("NOTIFY_BIN", "notify"))
    ap.add_argument("--state-dir", help="where the notify ledger lives (default <city>/.gc/runtime/packs/town-deltas)")
    ap.add_argument("--cannot-tell-cooldown-min", type=float, default=CANNOT_TELL_COOLDOWN_MIN_DEFAULT,
                    help="minimum minutes between two CANNOT TELL notices for the same reasons (default %g)" % CANNOT_TELL_COOLDOWN_MIN_DEFAULT)
    ap.add_argument("--now", help="RFC3339 'now' (tests)")
    ap.add_argument("--log", help="append the run summary (json line) here")
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
