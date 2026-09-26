#!/usr/bin/env python3
"""Selftest for portaria_shadow.py (ga-aijm2v.4 — Portaria do Jev v1, modo SOMBRA).

Every test states the production failure it catches ("Catches:"). Expectations are hand-written
literals, never computed by the code under test. No network, no real bd/gc/Jev: the module's
seams (jev_fn, bd_fn, now) are injected; events/nudges/state live in a throwaway directory.

Run:  python3 portaria-shadow.selftest.py        (or the .selftest.sh wrapper)
Exit: 0 = all pass, non-zero = any failure (an ImportError means the Portaria is not there yet).
"""
from __future__ import annotations

import gzip
import importlib.util
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("portaria_shadow", HERE / "portaria_shadow.py")
ps = importlib.util.module_from_spec(spec)
sys.modules["portaria_shadow"] = ps  # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(ps)  # ImportError/FileNotFoundError here = "the Portaria does not exist yet"

PASS = 0
FAIL = 0


def ok(label: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok  {label}")
    else:
        FAIL += 1
        print(f"  FAIL {label}" + (f"  [{detail}]" if detail else ""))


T0 = datetime(2026, 9, 25, 18, 0, 0, tzinfo=timezone.utc)


def iso_local(dt: datetime) -> str:
    """The shape events.jsonl really has: local -03:00 with microseconds."""
    return dt.astimezone(timezone(timedelta(hours=-3))).strftime("%Y-%m-%dT%H:%M:%S.123456-03:00")


def iso_z(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def ev_mail(seq, dt, mid, to, subject, body="", frm="human", thread="thread-x"):
    return {"seq": seq, "type": "mail.sent", "ts": iso_local(dt), "actor": frm, "subject": mid, "message": to,
            "payload": {"message": {"id": mid, "from": frm, "to": to, "subject": subject, "body": body,
                                    "created_at": iso_z(dt), "thread_id": thread}, "rig": ""}}


def ev_bead(seq, dt, entity, typ="bead.updated", actor="cache-reconcile"):
    return {"seq": seq, "type": typ, "ts": iso_local(dt), "actor": actor, "subject": entity, "payload": {"id": entity}}


def ev_fill(seq, dt):
    return {"seq": seq, "type": "order.completed", "ts": iso_local(dt), "actor": "controller", "subject": "x"}


class Env:
    def __init__(self, root: Path):
        self.root = root
        (root / ".gc" / "nudges").mkdir(parents=True, exist_ok=True)
        (root / ".gc" / "logs").mkdir(parents=True, exist_ok=True)
        self.events = root / ".gc" / "events.jsonl"
        self.nudges = root / ".gc" / "nudges" / "state.json"
        self.jev_log = root / ".gc" / "logs" / "jev-experiment.jsonl"
        self.state = root / "state" / "portaria-shadow-state.json"
        self.write_events([])
        self.write_nudges([], [])
        self.jev_calls: list = []
        self.bd_calls: list = []
        self.jev_answers = {"precisa_agir": 0.60, "duplicata": 0.20, "resolve_sozinho": 0.20}
        self.jev_ok = True
        self.comments: dict = {}       # entity -> list of comment dicts, or None = bd failed
        self.show: dict = {}           # entity -> bead dict for `bd show`

    def write_events(self, evs, path=None):
        (path or self.events).write_text("".join(json.dumps(e) + "\n" for e in evs), encoding="utf-8")

    def write_nudges(self, pending, dead):
        self.nudges.write_text(json.dumps({"pending": pending, "dead": dead}), encoding="utf-8")

    def cfg(self, **kw):
        base = dict(city=self.root, events_file=self.events, nudge_state=self.nudges, state_file=self.state,
                    jev_log=self.jev_log, janela_min=60, grace_s=120, confidence=0.85, max_per_run=30,
                    dup_window_min=120, bootstrap="start", rig_paths={"ga": str(self.root), "wa": str(self.root / "wa")})
        base.update(kw)
        return ps.Config(**base)

    def jev_fn(self, state, questions):
        self.jev_calls.append((state, sorted(questions)))
        if not self.jev_ok:
            return {"ok": False, "error": "network: URLError: down"}
        return {"ok": True, "answers": dict(self.jev_answers), "bad": {}, "tokens_in": 400, "tokens_out": 30}

    def bd_fn(self, rig_path, args):
        self.bd_calls.append(list(args))
        sub, ent = args[0], args[1]
        if sub == "comments":
            c = self.comments.get(ent)
            return (1, "") if c is None else (0, json.dumps(c))
        if sub == "show":
            b = self.show.get(ent)
            return (1, "") if b is None else (0, json.dumps([b]))
        raise AssertionError(f"consumer issued a non-read bd command: {args}")

    def run(self, now, **kw):
        return ps.run_once(self.cfg(**kw), jev_fn=self.jev_fn, bd_fn=self.bd_fn, now=now)

    def log_lines(self):
        if not self.jev_log.exists():
            return []
        return [json.loads(l) for l in self.jev_log.read_text().splitlines() if l.strip()]

    def portaria_records(self):
        return [r for r in self.log_lines() if r.get("mode") == "portaria"]


def with_env(fn):
    with tempfile.TemporaryDirectory() as td:
        fn(Env(Path(td)))


ORPHAN_SUBJ = "Watchdog: 2 bead(s) com gate:* label e zero marker ativo (>=180min)"
ORPHAN_BODY = "NEW/DUE (2)\n  wa-aaa11  (/Users/athos/gt/whatsapp_automation)  age=265min  labels=[gate:passed]\n  wa-bbb22  age=187min"

# ---------------------------------------------------------------------------------------------
print("-- 1. classification: real subjects (measured over ~40h of the Mayor's mail) -> classes --")
cl = lambda s: ps.classify_mail(s)[0]
ok("'Dolt disk-floor CRITICAL: avail=3GB' -> disk-floor", cl("Dolt disk-floor CRITICAL: avail=3GB") == "disk-floor")
ok("'Dolt disk-floor RECOVERED' -> disk-floor", cl("Dolt disk-floor RECOVERED: avail=25GB") == "disk-floor")
ok("gate held (both phrasings) -> gate-held",
   cl("Gate held for daemon verification: wa-1 (ga-2)") == "gate-held"
   and cl("Your gate PASS is held for daemon verification: wa-1 (ga-2)") == "gate-held")
ok("orphan-label watchdog -> gate-orphan-label", cl(ORPHAN_SUBJ) == "gate-orphan-label")
ok("'Gate: author unreachable for wa-1' -> gate-author-unreachable", cl("Gate: author unreachable for wa-1") == "gate-author-unreachable")
ok("'Decisão pendente: ga-1 (next-action:mayor)' is PROTECTED (an explicit decision request)",
   ps.classify_mail("Decisão pendente: ga-1 (next-action:mayor)") == ("decisao-pendente", True, "subject"))
ok("'ESCALATION: Dolt server unreachable' is PROTECTED",
   ps.classify_mail("ESCALATION: Dolt server unreachable on port 52756 [CRITICAL]")[1] is True)
ok("unknown subject -> 'outros', never protected-by-accident and never rule-skippable",
   ps.classify_mail("Algo que nunca vimos") == ("outros", False, "subject"))

# ---------------------------------------------------------------------------------------------
print("-- 2. entity extraction: only bead-shaped ids, sub-ids and wisps included --")
ok("ids with sub-issue suffix and wisp form",
   ps.extract_entities("ver ga-aijm2v.4 e ga-wisp-cv695j, wa-01iuf") == ["ga-aijm2v.4", "ga-wisp-cv695j", "wa-01iuf"])
ok("ordinary words that contain a dash are not entities", ps.extract_entities("re-run, time-out, ga-") == [])
ok("pool/session names are not beads (wa-worker, wa-worker-1, ps-worker-adhoc-x)",
   ps.extract_entities("crew/wa-worker/wa-abc12 for wa-worker-1 and ps-worker-adhoc-9") == ["wa-abc12"])
ORPHAN_REAL = ("GATE ORPHANED-LABEL WATCHDOG — detection-only report (ga-l8yh6, follow-up of ga-d3eg2 AC4).\n\n"
               "GATE ORPHANED LABEL: 1 new/due, 1 resolved.\n\nNEW/DUE (2) — why this cycle alerted:\n"
               "  wa-0lagb  (/Users/athos/gt/whatsapp_automation)  age=222min  labels=[gate:passed]\n"
               "  wa-v542i  (/Users/athos/gt/whatsapp_automation)  age=187min\n\n"
               "RESOLVED (1) since last alert:\n  wa-01iuf  (no longer carries an orphaned gate:* label)\n\nThis is SURFACE-ONLY (ga-cjk1j)")
ok("orphan-label body: only the NEW/DUE list — not the boilerplate refs (ga-l8yh6, ga-d3eg2) nor the RESOLVED bead",
   ps.entities_from("list", "x", ORPHAN_REAL) == ["wa-0lagb", "wa-v542i"], str(ps.entities_from("list", "x", ORPHAN_REAL)))
ok("no NEW/DUE section -> no entity (never guessed from prose)", ps.entities_from("list", "x", "ga-l8yh6 follow-up of ga-d3eg2") == [])
ok("'Beads sem rota': the flagged beads, not the 'Ver ...' references",
   ps.entities_from("sem-rota", "Beads sem rota", "1 em andamento sem gc.routed_to: wa-lch7d. Ver wa-t9jbv/ga-1b40v8/wa-ved13") == ["wa-lch7d"])
ok("subject: the FIRST id only (the parenthesised one is the mechanism)",
   ps.entities_from("subject", "Gate held for daemon verification: wa-vxpv4 (ga-l7n3v)", "") == ["wa-vxpv4"])
ok("duplicates collapse, first-seen order kept", ps.extract_entities("wa-aaa11 wa-bbb22 wa-aaa11") == ["wa-aaa11", "wa-bbb22"])
# Catches (gate ga-aijm2v.4, low): the NEW/DUE block is "\n".join(lines) with NO trailing newline, so the
# id on the LAST line has no whitespace after it — a `(?=\s)` lookahead silently dropped exactly that id.
ok("the id on the LAST line of the NEW/DUE block (no trailing newline, no trailing text) is kept",
   ps.entities_from("list", "x", "NEW/DUE (2) — why\n  wa-aaa11  age=3min\n  wa-zzz99") == ["wa-aaa11", "wa-zzz99"],
   str(ps.entities_from("list", "x", "NEW/DUE (2) — why\n  wa-aaa11  age=3min\n  wa-zzz99")))
ok("...and when the body ends right after a blank line the section still stops there",
   ps.entities_from("list", "x", "NEW/DUE (1) — why\n  wa-aaa11\n\nRESOLVED (1)\n  wa-old99") == ["wa-aaa11"])

# ---------------------------------------------------------------------------------------------
print("-- 3. delivery observation: each mail once, across runs, incl. rotation --")


def t_discovery(e: Env):
    e.write_events([ev_mail(10, T0, "m1", "gastown.mayor", "Beads sem rota", "1 sem rota"),
                    ev_mail(11, T0 + timedelta(minutes=1), "m2", "gastown.mayor", "Beads sem rota", "1 sem rota 2")])
    s1 = e.run(T0 + timedelta(minutes=5))
    ok("run 1 observes both mails", s1["new"] == 2, str(s1))
    s2 = e.run(T0 + timedelta(minutes=6))
    ok("run 2 over the SAME events observes nothing new (cursor) — no double count", s2["new"] == 0, str(s2))
    # a delivery that lands between runs must not be lost
    ev = [json.loads(l) for l in e.events.read_text().splitlines()]
    ev.append(ev_mail(12, T0 + timedelta(minutes=7), "m3", "gastown.mayor", "Beads sem rota", "3"))
    e.write_events(ev)
    s3 = e.run(T0 + timedelta(minutes=8))
    ok("run 3 picks up the mail that arrived after run 2 (nothing lost)", s3["new"] == 1, str(s3))
    e.run(T0 + timedelta(minutes=90))  # resolves all three (no fillers -> stays pending)
    ids = sorted(json.loads(e.state.read_text())["pending"])
    ok("delivery ids in state are mail:<id> and unique", ids == ["mail:m1", "mail:m2", "mail:m3"], str(ids))
    st = json.loads(e.state.read_text())
    ok("cursor advanced to the last seq seen", st["cursor_seq"] == 12, str(st.get("cursor_seq")))


with_env(t_discovery)


def t_cursor_quiet(e: Env):
    """Catches: a cursor that only moves on mail. In a quiet stretch (thousands of order/bead events,
    no mail) it would stay put and every run would re-scan everything since activation — and, once
    the file rotates, re-read the archives too."""
    e.write_events([ev_mail(1, T0, "q1", "gastown.mayor", "Beads sem rota", "x")] + [ev_fill(s, T0 + timedelta(seconds=s)) for s in range(2, 40)])
    e.run(T0 + timedelta(minutes=5))
    ok("cursor advances over trailing non-mail events (to the last seq seen)", json.loads(e.state.read_text())["cursor_seq"] == 39)
    e.run(T0 + timedelta(minutes=6))
    ok("...and stays there on a quiet re-run", json.loads(e.state.read_text())["cursor_seq"] == 39)


with_env(t_cursor_quiet)


def t_rotation(e: Env):
    """Catches: events.jsonl rotates (~every 2 days). A cursor older than the live file's first
    seq must read the newest archive, else every mail delivered around the rotation is lost."""
    arch = e.root / ".gc" / "events.jsonl.archive-20260925T180200Z-seq-100-199.gz"
    with gzip.open(arch, "wt") as f:
        f.write(json.dumps(ev_mail(150, T0 + timedelta(minutes=1), "old1", "gastown.mayor", "Beads sem rota", "x")) + "\n")
        f.write(json.dumps(ev_mail(199, T0 + timedelta(minutes=2), "old2", "gastown.mayor", "Beads sem rota", "y")) + "\n")
    e.write_events([{"seq": 200, "type": "events.rotated", "ts": iso_local(T0 + timedelta(minutes=3)), "actor": "events",
                     "payload": {"prior_first_seq": 100, "prior_last_seq": 199}},
                    ev_mail(201, T0 + timedelta(minutes=4), "new1", "gastown.mayor", "Beads sem rota", "z")])
    e.state.parent.mkdir(parents=True, exist_ok=True)
    e.state.write_text(json.dumps({"cursor_seq": 149, "nudges_seen": {}, "pending": {}, "resolved_ids": {}, "dup_ledger": {}, "jev_fail_streak": 0}))
    s = e.run(T0 + timedelta(minutes=10))
    got = sorted(json.loads(e.state.read_text())["pending"])
    ok("mails from the archive AND the live file are all observed", got == ["mail:new1", "mail:old1", "mail:old2"], str(got))
    ok("no event is observed twice", s["new"] == 3, str(s))


with_env(t_rotation)


def t_activation_unreadable(e: Env):
    """Catches: an events file that is unreadable at activation became cursor 0 -> the next run
    re-read 40h of archives and flooded Jev with stale 'deliveries'."""
    e.events.write_text("")
    s = e.run(T0 + timedelta(minutes=5), bootstrap="tail")
    ok("empty/unreadable events file at activation -> skipped, no state written", s.get("skipped") == "events_unreadable_at_activation" and not e.state.exists(), str(s))
    e.write_events([ev_mail(10, T0, "a", "gastown.mayor", "Beads sem rota", "x")])
    s2 = e.run(T0 + timedelta(minutes=6), bootstrap="tail")
    ok("once the file is readable it activates at ITS last seq (nothing old is replayed)", s2["new"] == 0 and json.loads(e.state.read_text())["cursor_seq"] == 10, str(s2))


with_env(t_activation_unreadable)


def t_gap(e: Env):
    """Catches: an archive pruned before it was read = deliveries lost; the run line must say so."""
    e.write_events([{"seq": 300, "type": "events.rotated", "ts": iso_local(T0), "actor": "events", "payload": {}},
                    ev_mail(301, T0 + timedelta(minutes=1), "g1", "gastown.mayor", "Beads sem rota", "x")])
    e.state.parent.mkdir(parents=True, exist_ok=True)
    e.state.write_text(json.dumps({"cursor_seq": 100, "nudges_seen": {}, "pending": {}, "resolved_ids": {}, "dup_ledger": {}}))
    s = e.run(T0 + timedelta(minutes=5))
    ok("cursor 100, live file starts at 300, no archive -> 199 seqs reported lost", s.get("gap_events") == 199, str(s))
    arch = e.root / ".gc" / "events.jsonl.archive-20260925T180000Z-seq-101-299.gz"
    with gzip.open(arch, "wt") as f:
        f.write(json.dumps(ev_fill(200, T0)) + "\n")
    e.state.write_text(json.dumps({"cursor_seq": 100, "nudges_seen": {}, "pending": {}, "resolved_ids": {}, "dup_ledger": {}}))
    s2 = e.run(T0 + timedelta(minutes=6))
    ok("an archive that covers the hole -> no gap reported", "gap_events" not in s2, str(s2))


with_env(t_gap)


def t_jev_garbage(e: Env):
    """Catches: a non-numeric / out-of-range primary answer crashing the run (or being read as a skip)."""
    e.write_events([ev_mail(1, T0, "z1", "gastown.mayor", "Gate: author unreachable for ga-zz1a", "x"),
                    ev_mail(2, T0, "z2", "gastown.mayor", "Gate: author unreachable for ga-zz2a", "x")])
    outs = iter(["muito", -0.5])
    def fn(state, questions):
        return {"ok": True, "answers": {"precisa_agir": next(outs)}, "bad": {}, "tokens_in": 1, "tokens_out": 1}
    ps.run_once(e.cfg(), jev_fn=fn, bd_fn=e.bd_fn, now=T0 + timedelta(minutes=5))
    p = json.loads(e.state.read_text())["pending"]
    ok("non-numeric and out-of-range primary answers -> nao_sei with the reason, run survives",
       p["mail:z1"]["camada2"] == "nao_sei" and p["mail:z2"]["camada2"] == "nao_sei" and "bad_primary_answer" in p["mail:z1"]["jev_error"], str(p))


with_env(t_jev_garbage)


def t_rig_warning(e: Env):
    e.write_events([ev_mail(1, T0, "w1", "gastown.mayor", "Beads sem rota", "x")])
    s = e.run(T0 + timedelta(minutes=5), rig_paths={"ga": str(e.root)})
    ok("a rig map with only the HQ raises a visible warning in the run line", "warning" in s and "nao_sei" in s["warning"], str(s))


with_env(t_rig_warning)


def t_bootstrap_tail(e: Env):
    """Catches: a first run that backfills 40h of history would read TODAY's bead state as if it
    were the state at delivery time (the live facts fed to Jev) — non-comparable data."""
    e.write_events([ev_mail(10, T0, "old", "gastown.mayor", "Beads sem rota", "x")])
    s = e.run(T0 + timedelta(minutes=5), bootstrap="tail")
    ok("bootstrap=tail: pre-existing mail is NOT recorded", s["new"] == 0, str(s))
    ev = [json.loads(l) for l in e.events.read_text().splitlines()]
    ev.append(ev_mail(11, T0 + timedelta(minutes=6), "fresh", "gastown.mayor", "Beads sem rota", "x"))
    e.write_events(ev)
    s2 = e.run(T0 + timedelta(minutes=7), bootstrap="tail")
    ok("bootstrap=tail: a mail after activation IS recorded", s2["new"] == 1, str(s2))


with_env(t_bootstrap_tail)

# ---------------------------------------------------------------------------------------------
print("-- 4. layer 1 (fixed rule) --")


def t_dup(e: Env):
    """Catches: the same alert repeating every cycle (32 of 65 mails in the epic's 24h) must be
    'pular' after the first — and the FIRST must never be skipped."""
    e.write_events([ev_mail(1, T0, "a1", "gastown.mayor", ORPHAN_SUBJ, ORPHAN_BODY),
                    ev_mail(2, T0 + timedelta(minutes=15), "a2", "gastown.mayor", ORPHAN_SUBJ, ORPHAN_BODY),
                    ev_mail(3, T0 + timedelta(minutes=30), "a3", "gastown.mayor", ORPHAN_SUBJ, ORPHAN_BODY),
                    ev_mail(4, T0 + timedelta(minutes=16), "u1", "gastown.mayor", "Algo desconhecido", "wa-ccc33"),
                    ev_mail(5, T0 + timedelta(minutes=31), "u2", "gastown.mayor", "Algo desconhecido", "wa-ccc33")])
    e.run(T0 + timedelta(minutes=35))
    p = json.loads(e.state.read_text())["pending"]
    ok("first occurrence: camada1=seguir", p["mail:a1"]["camada1"] == "seguir")
    ok("repeat within window: camada1=pular, regra=duplicata", p["mail:a2"]["camada1"] == "pular" and p["mail:a2"]["camada1_regra"] == "duplicata")
    ok("chain: the third repeat is still a duplicate of the second", p["mail:a3"]["camada1"] == "pular")
    ok("class 'outros' is NEVER rule-skipped, even when identical", p["mail:u2"]["camada1"] == "seguir")


with_env(t_dup)


def t_dup_key_entityless(e: Env):
    """Catches: an alert with no cited entity is deduped by its subject modulo numbers — so a disk
    alert repeating with a different number IS a repeat, but RECOVERED after CRITICAL is NOT (a
    'recovered' swallowed as a duplicate would hide the end of an incident)."""
    e.write_events([ev_mail(1, T0, "k1", "gastown.mayor", "Dolt disk-floor CRITICAL: avail=3GB", "x"),
                    ev_mail(2, T0 + timedelta(minutes=15), "k2", "gastown.mayor", "Dolt disk-floor CRITICAL: avail=2GB", "x"),
                    ev_mail(3, T0 + timedelta(minutes=20), "k3", "gastown.mayor", "Dolt disk-floor RECOVERED: avail=25GB", "x"),
                    ev_mail(4, T0 + timedelta(minutes=25), "k4", "oracle-wa", "Dolt disk-floor CRITICAL: avail=2GB", "x")])
    e.run(T0 + timedelta(minutes=30))
    p = json.loads(e.state.read_text())["pending"]
    ok("CRITICAL repeating with another number is a duplicate", p["mail:k2"]["camada1"] == "pular")
    ok("RECOVERED is a different alert, never a duplicate of CRITICAL", p["mail:k3"]["camada1"] == "seguir")
    ok("the same alert to ANOTHER recipient is not a duplicate for them", p["mail:k4"]["camada1"] == "seguir")


with_env(t_dup_key_entityless)


def t_protected(e: Env):
    """Catches: an explicit decision request ('Decisão pendente') exists to demand attention —
    deduping or asking Jev to suppress it defeats it. Must go through untouched, Jev not even asked."""
    subj = "Decisão pendente: ga-bbb22 (next-action:mayor)"
    e.write_events([ev_mail(1, T0, "d1", "gastown.mayor", subj, "b"), ev_mail(2, T0 + timedelta(minutes=5), "d2", "gastown.mayor", subj, "b")])
    e.jev_answers = {"precisa_agir": 0.01, "duplicata": 0.99, "resolve_sozinho": 0.99}
    e.run(T0 + timedelta(minutes=10))
    p = json.loads(e.state.read_text())["pending"]
    ok("protected: camada1=seguir with regra=protegida (even the repeat)", p["mail:d2"]["camada1"] == "seguir" and p["mail:d2"]["camada1_regra"] == "protegida")
    ok("protected: camada2=nao_avaliada and Jev was never called", p["mail:d2"]["camada2"] == "nao_avaliada" and e.jev_calls == [])
    ok("protected: cascata=seguir, camada3=acordaria", p["mail:d2"]["cascata"] == "seguir" and p["mail:d2"]["camada3"] == "acordaria")


with_env(t_protected)


def t_pool_routed(e: Env):
    """Catches: 'author unreachable' for a bead that is ALREADY gate:needs-fix and routed to the
    pool heals itself; waking the Mayor is pure waste. But a bead NOT routed must still wake."""
    e.show["wa-aaa11"] = {"id": "wa-aaa11", "status": "open", "assignee": "", "labels": ["gate:needs-fix"], "metadata": {"gc.routed_to": "wa-worker"}}
    e.show["wa-bbb22"] = {"id": "wa-bbb22", "status": "open", "assignee": "", "labels": ["gate:needs-fix"], "metadata": {}}
    e.write_events([ev_mail(1, T0, "r1", "gastown.mayor", "Gate: author unreachable for wa-aaa11", "x"),
                    ev_mail(2, T0 + timedelta(minutes=1), "r2", "gastown.mayor", "Gate: author unreachable for wa-bbb22", "x")])
    e.run(T0 + timedelta(minutes=5))
    p = json.loads(e.state.read_text())["pending"]
    ok("needs-fix + routed to pool -> pular (bead-ja-roteada-pro-pool)", p["mail:r1"]["camada1"] == "pular" and p["mail:r1"]["camada1_regra"] == "bead-ja-roteada-pro-pool")
    ok("needs-fix but NOT routed -> seguir", p["mail:r2"]["camada1"] == "seguir")


with_env(t_pool_routed)

# ---------------------------------------------------------------------------------------------
print("-- 5. layer 2 (Jev): third state is never 'pular' --")


def t_jev_thresholds(e: Env):
    e.write_events([ev_mail(i, T0 + timedelta(minutes=i), f"j{i}", "gastown.mayor", f"Gate: author unreachable for ga-jj{i}a", "x") for i in (1, 2, 3, 4)])
    answers = iter([0.05, 0.14, 0.15, 0.50])   # 1-noul: .95 / .86 / .85(border) / .50
    orig = e.jev_fn

    def seq_fn(state, questions):
        r = orig(state, questions)
        r["answers"] = {"precisa_agir": next(answers), "duplicata": 0.3, "resolve_sozinho": 0.4}
        return r
    ps.run_once(e.cfg(), jev_fn=seq_fn, bd_fn=e.bd_fn, now=T0 + timedelta(minutes=10))
    p = json.loads(e.state.read_text())["pending"]
    ok("noul .05 -> pular (95% sure NOT needed)", p["mail:j1"]["camada2"] == "pular")
    ok("noul .14 -> pular (86% >= 85%)", p["mail:j2"]["camada2"] == "pular")
    ok("noul .15 -> pular exactly AT the 85% bar (>=)", p["mail:j3"]["camada2"] == "pular")
    ok("noul .50 -> seguir (uncertain never skips)", p["mail:j4"]["camada2"] == "seguir")
    ok("camada2_noul is the raw primary answer, extras carry the fan-out answers",
       p["mail:j1"]["camada2_noul"] == 0.05 and p["mail:j1"]["camada2_extras"] == {"duplicata": 0.3, "resolve_sozinho": 0.4})
    ok("cascata: Jev pular alone is enough; camada3 then 'nao_alcancada'", p["mail:j1"]["cascata"] == "pular" and p["mail:j1"]["camada3"] == "nao_alcancada")
    ok("cascata: Jev seguir + rule seguir -> acordaria (falls through to Claude, as today)", p["mail:j4"]["cascata"] == "seguir" and p["mail:j4"]["camada3"] == "acordaria")


with_env(t_jev_thresholds)


def t_jev_down(e: Env):
    """Catches: Jev down/timeout MUST record 'nao_sei', never 'pular' (the spec's third-state rule)."""
    e.jev_ok = False
    e.write_events([ev_mail(i, T0 + timedelta(minutes=i), f"n{i}", "gastown.mayor", f"Gate: author unreachable for ga-nn{i}a", "x") for i in range(1, 7)])
    e.run(T0 + timedelta(minutes=10))
    p = json.loads(e.state.read_text())["pending"]
    ok("Jev error -> camada2 == nao_sei on every delivery", all(v["camada2"] == "nao_sei" for v in p.values()), str({k: v["camada2"] for k, v in p.items()}))
    ok("Jev error -> cascata is 'seguir' (never a skip on doubt)", all(v["cascata"] == "seguir" for v in p.values()))
    ok("the error is recorded, not swallowed", all(v["jev_error"] for v in p.values()))
    ok("circuit breaker: after 3 consecutive failures the run stops calling Jev", len(e.jev_calls) == 3, str(len(e.jev_calls)))
    ok("circuit-broken deliveries say so", p["mail:n6"]["jev_error"].startswith("circuit_open"), p["mail:n6"]["jev_error"])


with_env(t_jev_down)


def t_jev_partial(e: Env):
    """Catches: Jev answering the fan-out questions but SKIPPING the primary one must not read as
    'low probability of needing action' — a missing answer is not a 0."""
    e.write_events([ev_mail(1, T0, "p1", "gastown.mayor", "Beads sem rota", "x")])
    def fn(state, questions):
        return {"ok": True, "answers": {"duplicata": 0.9}, "bad": {"precisa_agir": "unparseable_answer: 'precisa_agir'"}, "tokens_in": 1, "tokens_out": 1}
    ps.run_once(e.cfg(), jev_fn=fn, bd_fn=e.bd_fn, now=T0 + timedelta(minutes=5))
    p = json.loads(e.state.read_text())["pending"]["mail:p1"]
    ok("primary answer missing -> nao_sei, not pular", p["camada2"] == "nao_sei" and p["cascata"] == "seguir")


with_env(t_jev_partial)


def t_jev_state_text(e: Env):
    """Catches: Jev judging on the alert text alone (the F1 lesson: it leaned wrong 61%) — the
    live facts of the cited bead must be in the state it reads."""
    e.show["wa-aaa11"] = {"id": "wa-aaa11", "status": "in_progress", "assignee": "wa-worker-1", "labels": ["gate:queued", "story:approved"], "metadata": {"gc.routed_to": "wa-worker"}}
    e.write_events([ev_mail(1, T0, "s1", "gastown.mayor", "Watchdog: 1 bead(s) com gate:* label e zero marker ativo (>=30min)", "NEW/DUE (1) — why:\n  wa-aaa11  (/x)  age=40min\n")])
    e.run(T0 + timedelta(minutes=5))
    state_text = e.jev_calls[0][0]
    ok("state carries the alert subject", "Watchdog: 1 bead(s)" in state_text)
    ok("state carries live status/assignee/labels/routing of the cited bead",
       "in_progress" in state_text and "wa-worker-1" in state_text and "gate:queued" in state_text and "gc.routed_to=wa-worker" in state_text)
    ok("the fan-out asks all three questions in ONE call", e.jev_calls[0][1] == ["duplicata", "precisa_agir", "resolve_sozinho"] and len(e.jev_calls) == 1)


with_env(t_jev_state_text)

# ---------------------------------------------------------------------------------------------
print("-- 6. outcome ('desfecho'): only ATTRIBUTABLE evidence counts as agiu --")


def outcome_scenario(e: Env, *, comments=None, extra_events=(), entity="ga-bbb22", fill=True, subject=None, body="", recipient="gastown.mayor", comments_fail=False):
    subject = subject or f"Gate: author unreachable for {entity}"
    evs = [ev_mail(1, T0, "o1", recipient, subject, body)]
    evs += list(extra_events)
    if fill:
        evs.append(ev_fill(900, T0 + timedelta(minutes=65)))
    e.write_events(evs)
    e.comments[entity] = None if comments_fail else (comments or [])
    e.run(T0 + timedelta(minutes=5))
    e.run(T0 + timedelta(minutes=70))
    return e.portaria_records()


def t_out_comment(e: Env):
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=20)), "text": "ok"}])
    ok("a comment BY the recipient on the entity inside the window -> agiu", len(recs) == 1 and recs[0]["desfecho"] == "agiu", str(recs))
    ok("the motive names the evidence", "comentario" in recs[0]["desfecho_motivo"])


with_env(t_out_comment)


def t_out_comment_other(e: Env):
    """Catches (gate ga-aijm2v.4, blocking #1): comment authors are NOT reliable identities — bd
    writes 'Test' (git-user fallback, agents' comments land there too) and 'automation', and the
    Mayor appears under two spellings. A comment in the window by an author that is not positively
    the recipient may BE the recipient, so reading it as "the recipient did not act" inflates
    pularia_seguro and under-counts erro_grave in the very report Athos uses to decide whether to
    enable suppression. It is the third state, exactly like an anonymous bead.* event."""
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "automation", "created_at": iso_z(T0 + timedelta(minutes=20)), "text": "x"}])
    ok("a comment by an author that is not the recipient -> nao_sei (never nao_agiu)", recs[0]["desfecho"] == "nao_sei", str(recs))
    ok("the motive names the author and says it is not attributable", "automation" in recs[0]["desfecho_motivo"] and "atribuivel" in recs[0]["desfecho_motivo"], recs[0]["desfecho_motivo"])


with_env(t_out_comment_other)


def t_out_comment_git_fallback_author(e: Env):
    """Catches: the reviewer's exact repro — a comment by 'Test' (1140 of ~1800 measured comments)
    inside the window was silently dropped and the delivery came out nao_agiu."""
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "Test", "created_at": iso_z(T0 + timedelta(minutes=20)), "text": "fixed it"}])
    ok("a comment by 'Test' (bd's git-user fallback) inside the window -> nao_sei", recs[0]["desfecho"] == "nao_sei", str(recs))


with_env(t_out_comment_git_fallback_author)


def t_out_comment_stray_outside_window(e: Env):
    """Catches the over-correction: if EVERY foreign comment on the entity turned the outcome nao_sei
    regardless of when it was written, old chatter on the bead would make nothing measurable and the
    report would say nothing. Only comments INSIDE the window are ambiguous."""
    recs = outcome_scenario(e, comments=[{"id": "c0", "author": "Test", "created_at": iso_z(T0 - timedelta(minutes=30)), "text": "before"},
                                         {"id": "c9", "author": "automation", "created_at": iso_z(T0 + timedelta(minutes=95)), "text": "after"}])
    ok("foreign comments BEFORE the delivery / AFTER the window leave the outcome nao_agiu", recs[0]["desfecho"] == "nao_agiu", str(recs))


with_env(t_out_comment_stray_outside_window)


def t_out_stray_comment_plus_recipient_comment(e: Env):
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "Test", "created_at": iso_z(T0 + timedelta(minutes=10)), "text": "x"},
                                         {"id": "c2", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=20)), "text": "done"}])
    ok("attributable comment wins over an unattributable one -> agiu", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_stray_comment_plus_recipient_comment)


def t_out_spelling_variants(e: Env):
    """Catches: the Mayor writes comments as 'gastown.mayor' (207) AND 'gastown__mayor' (50). Equality
    on the raw string credited only one spelling, so the same action counted as agiu or nao_sei
    depending on how bd spelled the author."""
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "gastown__mayor", "created_at": iso_z(T0 + timedelta(minutes=20)), "text": "ok"}])
    ok("the '__' spelling of the recipient's own name is the recipient -> agiu", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_spelling_variants)


def t_out_mail_spelling_variant(e: Env):
    recs = outcome_scenario(e, extra_events=[ev_mail(60, T0 + timedelta(minutes=10), "reply9", "athos", "Re", "resolvi ga-bbb22", frm="Gastown__Mayor")])
    ok("a mail sent under the other spelling / case of the recipient's name -> agiu", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_mail_spelling_variant)


def t_out_comment_unparseable(e: Env):
    """Catches: a comment whose date cannot be parsed, or that is not even an object, was skipped as
    'outside the window' — an error read as empty. It cannot be placed, so it is nao_sei."""
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "Test", "created_at": "not-a-date", "text": "x"}])
    ok("a comment with an unreadable date -> nao_sei, not 'outside the window'", recs[0]["desfecho"] == "nao_sei", str(recs))
    with_env(lambda e2: ok("a comment entry that is not an object -> nao_sei", outcome_scenario(e2, comments=["garbage"])[0]["desfecho"] == "nao_sei"))


with_env(t_out_comment_unparseable)


def t_out_mail_mention_is_whole_id(e: Env):
    """Catches: `x in text` substring matching credited 'ga-bbb22' for a mention of 'ga-bbb22x' or
    for its child 'ga-bbb22.4' — a different bead — as the recipient acting (false agiu)."""
    recs = outcome_scenario(e, extra_events=[ev_mail(60, T0 + timedelta(minutes=10), "m1", "athos", "Re", "vi ga-bbb22x e tambem ga-bbb22.4", frm="gastown.mayor", thread="thread-other")])
    ok("a mail by the recipient citing a DIFFERENT id that merely contains the entity is not 'acted on it'",
       recs[0]["desfecho"] == "nao_agiu", str(recs))
    with_env(lambda e2: ok("...but the exact id in a longer sentence still counts",
                           outcome_scenario(e2, extra_events=[ev_mail(60, T0 + timedelta(minutes=10), "m2", "athos", "Re", "resolvi ga-bbb22, ok?", frm="gastown.mayor", thread="thread-other")])[0]["desfecho"] == "agiu"))


with_env(t_out_mail_mention_is_whole_id)


def t_out_comment_outside(e: Env):
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=95)), "text": "late"},
                                         {"id": "c0", "author": "gastown.mayor", "created_at": iso_z(T0 - timedelta(minutes=5)), "text": "early"}])
    ok("comments before delivery / after the window do not count", recs[0]["desfecho"] == "nao_agiu", str(recs))


with_env(t_out_comment_outside)


def t_out_bead_event_unattributable(e: Env):
    """Catches (THE spec trap, measured 25/09): ALL 24,8k bead.* events in the last archive carry
    actor=cache-reconcile. Reading 'the recipient did not appear as actor' as 'the recipient did
    not act' would call every bead action 'nao_agiu' and make skipping look free. A change by an
    unknown author must be nao_sei, NOT nao_agiu."""
    recs = outcome_scenario(e, extra_events=[ev_bead(50, T0 + timedelta(minutes=12), "ga-bbb22")])
    ok("entity changed in the window but by an unattributable author -> nao_sei (never nao_agiu)", recs[0]["desfecho"] == "nao_sei", str(recs))
    ok("the motive says why", "sem autor" in recs[0]["desfecho_motivo"], recs[0]["desfecho_motivo"])


with_env(t_out_bead_event_unattributable)


def t_out_bead_event_plus_comment(e: Env):
    recs = outcome_scenario(e, comments=[{"id": "c1", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=12)), "text": "done"}],
                            extra_events=[ev_bead(50, T0 + timedelta(minutes=12), "ga-bbb22")])
    ok("attributable comment wins over the anonymous entity change -> agiu", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_bead_event_plus_comment)


def t_out_mail_reply(e: Env):
    recs = outcome_scenario(e, extra_events=[ev_mail(60, T0 + timedelta(minutes=10), "reply1", "athos", "Re: Gate: author unreachable", "resolvi ga-bbb22", frm="gastown.mayor", thread="thread-other")])
    ok("a mail SENT BY the recipient citing the entity in the window -> agiu", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_mail_reply)


def t_out_thread_reply(e: Env):
    evs = [ev_mail(60, T0 + timedelta(minutes=10), "reply2", "human", "Re: x", "sem id nenhum", frm="gastown.mayor", thread="thread-x")]
    recs = outcome_scenario(e, extra_events=evs)
    ok("a reply BY the recipient on the same thread -> agiu even without citing an id", recs[0]["desfecho"] == "agiu", str(recs))


with_env(t_out_thread_reply)


def t_out_mail_by_other(e: Env):
    recs = outcome_scenario(e, extra_events=[ev_mail(60, T0 + timedelta(minutes=10), "other1", "athos", "Re", "ga-bbb22 resolvido", frm="oracle-wa")])
    ok("a mail from SOMEONE ELSE citing the entity is not the recipient acting", recs[0]["desfecho"] == "nao_agiu", str(recs))


with_env(t_out_mail_by_other)


def t_out_read_is_not_action(e: Env):
    read = {"seq": 61, "type": "mail.read", "ts": iso_local(T0 + timedelta(minutes=9)), "actor": "gastown.mayor", "subject": "o1", "payload": {}}
    recs = outcome_scenario(e, extra_events=[read, dict(read, seq=62, type="mail.archived")])
    ok("mail.read / mail.archived by the recipient is reading, not acting -> nao_agiu", recs[0]["desfecho"] == "nao_agiu", str(recs))


with_env(t_out_read_is_not_action)


def t_out_comments_unreadable(e: Env):
    """Catches: bd failing (Dolt down) reads as an empty comment list -> 'nao_agiu' — the
    error/empty conflation this city has been bitten by 6x."""
    recs = outcome_scenario(e, comments_fail=True)
    ok("comments channel unreadable -> nao_sei, NEVER nao_agiu", recs[0]["desfecho"] == "nao_sei", str(recs))
    ok("motive names the unreadable channel", "ilegiv" in recs[0]["desfecho_motivo"], recs[0]["desfecho_motivo"])


with_env(t_out_comments_unreadable)


def t_out_no_entity(e: Env):
    recs = outcome_scenario(e, subject="Beads sem rota", body="nenhum id aqui")
    ok("no identifiable entity -> nao_sei (not nao_agiu)", recs[0]["desfecho"] == "nao_sei" and "entidade" in recs[0]["desfecho_motivo"], str(recs))


with_env(t_out_no_entity)


def t_out_coverage(e: Env):
    """Catches: resolving before the events file covers the whole window would call a delivery
    'nao_agiu' just because the evidence had not been written yet."""
    outcome_scenario(e, fill=False)
    ok("no event covers the end of the window -> NOT resolved yet (still pending, no log line)",
       e.portaria_records() == [] and "mail:o1" in json.loads(e.state.read_text())["pending"])
    ev = [json.loads(l) for l in e.events.read_text().splitlines()]
    ev.append(ev_fill(901, T0 + timedelta(minutes=66)))
    e.write_events(ev)
    e.run(T0 + timedelta(minutes=71))
    ok("once an event past the window exists it resolves", len(e.portaria_records()) == 1)


with_env(t_out_coverage)


def t_out_multi_entity(e: Env):
    e.comments["wa-aaa11"] = []
    e.comments["wa-bbb22"] = [{"id": "c9", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=30)), "text": "x"}]
    e.write_events([ev_mail(1, T0, "o1", "gastown.mayor", ORPHAN_SUBJ, ORPHAN_BODY), ev_fill(900, T0 + timedelta(minutes=65))])
    e.run(T0 + timedelta(minutes=5))
    e.run(T0 + timedelta(minutes=70))
    r = e.portaria_records()
    ok("evidence on ANY of the cited entities counts (orphan-label lists several beads)",
       r[0]["desfecho"] == "agiu" and r[0]["entidades"] == ["wa-aaa11", "wa-bbb22"], str(r))


with_env(t_out_multi_entity)

# ---------------------------------------------------------------------------------------------
print("-- 6b. events that cannot be read are 'cannot tell', never 'nothing happened' (gate blocking #2) --")
import io  # noqa: E402

ARCH_NAME = "events.jsonl.archive-20260925T181500Z-seq-1-202.gz"


def observe_then_rotate(e: Env, *, cut: int = 12) -> bytes:
    """The real sequence: delivery o1 is observed from the LIVE file; then events.jsonl rotates. The
    archive holds o1 (seq 1), 200 unrelated events and — as its LAST line — the bead.updated of the
    entity o1 cites (seq 202); the new live file only proves the window closed. The archive is cut
    mid-stream: reading it raises EOFError after seq 201, so the entity's change is LOST (the
    reviewer's repro: 'rotated archive truncated mid-stream, the entity's bead.updated is its last
    line'). Returns the intact archive bytes."""
    e.write_events([ev_mail(1, T0, "o1", "gastown.mayor", "Gate: author unreachable for ga-bbb22")])
    e.comments["ga-bbb22"] = []
    s1 = e.run(T0 + timedelta(minutes=5))
    assert "mail:o1" in json.loads(e.state.read_text())["pending"], s1
    lines = [ev_mail(1, T0, "o1", "gastown.mayor", "Gate: author unreachable for ga-bbb22")]
    lines += [ev_fill(i, T0 + timedelta(minutes=1, seconds=i % 50)) for i in range(2, 202)]
    lines.append(ev_bead(202, T0 + timedelta(minutes=12), "ga-bbb22"))
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb") as g:
        g.write("".join(json.dumps(x) + "\n" for x in lines).encode())
    whole = raw.getvalue()
    (e.root / ".gc" / ARCH_NAME).write_bytes(whole[:-cut] if cut else whole)
    e.write_events([ev_fill(203, T0 + timedelta(minutes=65))])
    return whole


def t_unreadable_defers(e: Env):
    """Catches (blocking #2): stats["unreadable_files"] was counted and never read, so a truncated
    archive resolved the delivery whose evidence it hid as nao_agiu ('nothing changed') — an error
    read as empty. Within the retry window the delivery must stay PENDING (the next run usually reads
    the file whole) and the run line must SAY the file was unreadable."""
    observe_then_rotate(e)
    s2 = e.run(T0 + timedelta(minutes=70))
    ok("window closed but its events were read only in part -> NOT resolved (no log line)", e.portaria_records() == [], str(e.portaria_records()))
    ok("...it stays pending", "mail:o1" in json.loads(e.state.read_text())["pending"], str(s2))
    ok("...and the run line says it was deferred for that reason", s2.get("deferred_unreadable") == 1, str(s2))
    ok("the run line reports the unreadable file (never silent)", s2.get("unreadable_files", 0) >= 1, str(s2))


with_env(t_unreadable_defers)


def t_unreadable_repaired(e: Env):
    whole = observe_then_rotate(e)
    e.run(T0 + timedelta(minutes=70))
    (e.root / ".gc" / ARCH_NAME).write_bytes(whole)  # the rotation race / transient I/O is gone
    s = e.run(T0 + timedelta(minutes=75))
    recs = e.portaria_records()
    ok("once the file reads whole the delivery resolves — with the change it had hidden -> nao_sei",
       len(recs) == 1 and recs[0]["desfecho"] == "nao_sei" and "mudou na janela" in recs[0]["desfecho_motivo"], str(recs))
    ok("...and the deferral counter is gone from the run line", "deferred_unreadable" not in s, str(s))


with_env(t_unreadable_repaired)


def t_unreadable_permanent(e: Env):
    """Catches: keeping a delivery pending forever behind a permanently bad archive (wedge), OR
    settling it as nao_agiu once the retry runs out. Past the retry it becomes nao_sei."""
    observe_then_rotate(e)
    e.run(T0 + timedelta(minutes=70))
    ok("inside the retry window it is still pending", e.portaria_records() == [])
    e.run(T0 + timedelta(minutes=60 + 120 + 5), unreadable_retry_min=120)
    recs = e.portaria_records()
    ok("permanently unreadable: settled as nao_sei after the retry (never wedged, never nao_agiu)",
       len(recs) == 1 and recs[0]["desfecho"] == "nao_sei", str(recs))
    ok("the motive says the events were unreadable", bool(recs) and "eventos ilegiveis" in recs[0]["desfecho_motivo"], str(recs))
    ok("nothing stays pending afterwards", json.loads(e.state.read_text())["pending"] == {})


with_env(t_unreadable_permanent)


def t_unreadable_positive_evidence_still_counts(e: Env):
    """Missing events can only HIDE a change, never un-see the recipient's own comment — positive,
    attributable evidence is still agiu even when the events could not be read whole."""
    rec = {"destinatario": "gastown.mayor", "entidades": ["ga-bbb22"], "seq": 1}
    t0, t1 = T0, T0 + timedelta(minutes=60)
    cs = {"ga-bbb22": [{"id": "c1", "author": "gastown.mayor", "created_at": iso_z(T0 + timedelta(minutes=9)), "text": "x"}]}
    ok("recipient's own comment + incomplete events -> agiu", ps.compute_outcome(rec, t0, t1, [], cs, events_complete=False)[0] == "agiu")
    ok("no evidence + incomplete events -> nao_sei", ps.compute_outcome(rec, t0, t1, [], {"ga-bbb22": []}, events_complete=False)[0] == "nao_sei")
    ok("no evidence + complete events -> nao_agiu (the incomplete flag is the only difference)", ps.compute_outcome(rec, t0, t1, [], {"ga-bbb22": []}, events_complete=True)[0] == "nao_agiu")


with_env(t_unreadable_positive_evidence_still_counts)


def t_corrupt_deflate(e: Env):
    """Catches: a corrupt deflate stream raises zlib.error — NOT an OSError/EOFError — so the whole run
    crashed and, since the cursor never advanced past the bad archive, EVERY later run crashed too
    (wedged for good). It must be counted as unreadable and the run must go on."""
    (e.root / ".gc" / "events.jsonl.archive-20260925T181500Z-seq-1-3.gz").write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03" + b"\xff" * 40)
    e.write_events([ev_mail(4, T0, "live1", "gastown.mayor", "Beads sem rota", "1 em andamento sem gc.routed_to: wa-lch7d.")])
    e.state.parent.mkdir(parents=True, exist_ok=True)  # cursor before the archive: the run must read it
    e.state.write_text(json.dumps({"cursor_seq": 0, "nudges_seen": {}, "pending": {}, "resolved_ids": {}, "dup_ledger": {}, "jev_fail_streak": 0}))
    try:
        s = e.run(T0 + timedelta(minutes=5))
        crashed = None
    except Exception as ex:  # noqa: BLE001
        s, crashed = {}, f"{type(ex).__name__}: {ex}"
    ok("a corrupt archive does not crash the run", crashed is None, str(crashed))
    ok("it is counted as unreadable on the run line", s.get("unreadable_files", 0) >= 1, str(s))
    ok("the good delivery in the live file is still observed", s.get("new") == 1, str(s))
    try:
        e.run(T0 + timedelta(minutes=6))
        again = True
    except Exception:  # noqa: BLE001
        again = False
    ok("...and the NEXT run works too (not wedged behind the bad archive)", again)


with_env(t_corrupt_deflate)

# ---------------------------------------------------------------------------------------------
print("-- 7. the log record --")


def t_record_shape(e: Env):
    e.jev_answers = {"precisa_agir": 0.05, "duplicata": 0.6, "resolve_sozinho": 0.7}
    recs = outcome_scenario(e, comments=[])
    r = recs[0]
    need = ["ts", "mode", "experiment", "classe", "canal", "delivery_id", "destinatario", "entidades", "fatos", "camada1", "camada1_regra",
            "camada2", "camada2_noul", "camada2_extras", "camada3", "cascata", "jev_ok", "jev_noul", "jev_error",
            "jev_tokens_in", "jev_tokens_out", "desfecho", "desfecho_motivo", "janela_min", "resolved_at"]
    ok("every field of the record is present", all(k in r for k in need), str([k for k in need if k not in r]))
    ok("mode=portaria and experiment=portaria-<classe>", r["mode"] == "portaria" and r["experiment"] == "portaria-gate-author-unreachable")
    ok("ts is the DELIVERY time in UTC (the day the message belongs to), not the resolution time", r["ts"] == "2026-09-25T18:00:00Z", r["ts"])
    ok("Jev's real token cost is on the record", r["jev_tokens_in"] == 400 and r["jev_tokens_out"] == 30 and r["jev_ok"] is True and r["jev_noul"] == 0.05)


with_env(t_record_shape)


def t_idempotent_log(e: Env):
    """Catches: 'run the consumer twice in a row must not duplicate records' — including the crash
    window between the log append and the state save (the state still says pending)."""
    e.write_events([ev_mail(1, T0, "o1", "gastown.mayor", "Gate: author unreachable for ga-bbb22", ""), ev_fill(900, T0 + timedelta(minutes=65))])
    e.comments["ga-bbb22"] = []
    e.run(T0 + timedelta(minutes=5))
    before_resolution = e.state.read_text()
    e.run(T0 + timedelta(minutes=70))
    ok("first resolution appends exactly one record", len(e.portaria_records()) == 1)
    e.run(T0 + timedelta(minutes=71)); e.run(T0 + timedelta(minutes=72))
    ok("re-running after resolution appends nothing", len(e.portaria_records()) == 1)
    e.state.write_text(before_resolution)      # the crash: log line written, state NOT saved
    e.run(T0 + timedelta(minutes=73))
    ok("state rolled back to 'still pending' -> the already-logged delivery is NOT appended again", len(e.portaria_records()) == 1)
    ok("...and it is no longer pending", "mail:o1" not in json.loads(e.state.read_text())["pending"])


with_env(t_idempotent_log)


def t_state_corrupt(e: Env):
    """Catches: a corrupt state file read as 'first run' — cursor and every pending outcome silently gone."""
    e.write_events([ev_mail(1, T0, "c1", "gastown.mayor", "Beads sem rota", "x")])
    e.state.parent.mkdir(parents=True, exist_ok=True)
    e.state.write_text("{ this is not json")
    s = e.run(T0 + timedelta(minutes=5))
    ok("corrupt state file -> the run says so in its line", "state_warning" in s and "state_corrupt" in s["state_warning"], str(s))
    ok("...and the bad file is kept aside as evidence, not deleted", any(p.name.startswith("portaria-shadow-state.json.corrupt-") for p in e.state.parent.iterdir()))


with_env(t_state_corrupt)


def t_log_unreadable(e: Env):
    """Catches: an existing-but-unreadable experiment log read as 'nothing logged yet' (-> duplicates)."""
    e.write_events([ev_mail(1, T0, "u1", "gastown.mayor", "Gate: author unreachable for ga-uu1a", "x"), ev_fill(900, T0 + timedelta(minutes=65))])
    e.comments["ga-uu1a"] = []
    e.run(T0 + timedelta(minutes=5))
    e.jev_log.mkdir(parents=True, exist_ok=True)       # the "log" is now a directory: open() raises IsADirectoryError
    s = e.run(T0 + timedelta(minutes=70))
    ok("unreadable log -> nothing resolved, warning raised, delivery stays pending",
       s["resolved"] == 0 and "log_warning" in s and "mail:u1" in json.loads(e.state.read_text())["pending"], str(s))


with_env(t_log_unreadable)


def t_no_mutation(e: Env):
    """Catches: shadow mode must NEVER change a delivery. The only external commands are the
    two bd READS; the default bd runner refuses anything else."""
    outcome_scenario(e, comments=[])
    ok("every bd call the consumer made was a read (show/comments)", all(c[0] in ("show", "comments") for c in e.bd_calls), str(e.bd_calls))
    try:
        ps.default_bd_runner("/tmp", ["update", "ga-1", "--claim"])
        refused = False
    except ValueError:
        refused = True
    ok("the default bd runner REFUSES a write subcommand", refused)
    for bad in (["mail", "archive", "x"], ["close", "ga-1"], ["comment", "ga-1", "x"], ["label", "add", "ga-1", "x"]):
        try:
            ps.default_bd_runner("/tmp", bad); refused = False
        except ValueError:
            refused = True
        ok(f"default bd runner refuses {bad[0]}", refused)


with_env(t_no_mutation)

# ---------------------------------------------------------------------------------------------
print("-- 8. nudges --")


def nudge(nid, agent, msg, bead, created):
    return {"id": nid, "bead_id": bead, "agent": agent, "session_id": agent, "source": "session", "message": msg,
            "created_at": created, "deliver_after": created, "expires_at": "2026-09-26T18:00:00Z"}


def t_nudge(e: Env):
    e.write_events([ev_fill(1, T0)])
    e.write_nudges([nudge("nudge-aaa", "gastown.dog-2", "check for assigned work", "ga-wisp-zzz111", iso_z(T0 + timedelta(minutes=1)))], [])
    s1 = e.run(T0 + timedelta(minutes=5))
    ok("a queued nudge is observed once", s1["new"] == 1)
    s2 = e.run(T0 + timedelta(minutes=6))
    ok("the same queued nudge is NOT observed again", s2["new"] == 0)
    p = json.loads(e.state.read_text())["pending"]["nudge:nudge-aaa"]
    ok("nudge is classified and carries canal=nudge, recipient=agent", p["canal"] == "nudge" and p["destinatario"] == "gastown.dog-2" and p["classe"] == "nudge-check-work")
    ok("an ephemeral wisp is NOT an outcome entity (it has no comment channel) but is kept for reference",
       p["entidades"] == [] and p["wisp"] == "ga-wisp-zzz111")
    # 65 min later the nudge left `pending` without being in `dead` = it was delivered
    e.write_events([ev_fill(1, T0), ev_fill(2, T0 + timedelta(minutes=70))])
    e.write_nudges([], [])
    e.comments["ga-wisp-zzz111"] = []
    e.run(T0 + timedelta(minutes=75))
    r = e.portaria_records()[0]
    ok("delivered nudge is recorded as such at resolution", r["nudge_estado"] == "entregue", str(r.get("nudge_estado")))


with_env(t_nudge)


def t_nudge_dead(e: Env):
    e.write_events([ev_fill(1, T0)])
    n = nudge("nudge-bbb", "gastown.dog-2", "check for assigned work", "ga-wisp-yyy222", iso_z(T0 + timedelta(minutes=1)))
    e.write_nudges([n], [])
    e.run(T0 + timedelta(minutes=5))
    e.write_events([ev_fill(1, T0), ev_fill(2, T0 + timedelta(minutes=70))])
    e.write_nudges([], [dict(n, last_error="expired", dead_at=iso_z(T0 + timedelta(minutes=68)))])
    e.comments["ga-wisp-yyy222"] = []
    e.run(T0 + timedelta(minutes=75))
    ok("a nudge that expired in `dead` is recorded as morta (it never woke anyone)", e.portaria_records()[0]["nudge_estado"] == "morta")


with_env(t_nudge_dead)


def t_nudge_bootstrap(e: Env):
    """Catches: the ~180 nudges already in the queue when the Portaria is switched on are not
    'deliveries since activation' and must not flood the first run with stale items."""
    e.write_events([ev_fill(1, T0)])
    e.write_nudges([nudge("nudge-old", "gastown.dog-2", "check for assigned work", "ga-wisp-old", iso_z(T0 - timedelta(hours=20)))], [])
    s = e.run(T0 + timedelta(minutes=5), bootstrap="tail")
    ok("bootstrap=tail: nudges already queued at activation are not recorded", s["new"] == 0, str(s))
    e.write_nudges([nudge("nudge-old", "gastown.dog-2", "check for assigned work", "ga-wisp-old", iso_z(T0 - timedelta(hours=20))),
                    nudge("nudge-new", "gastown.dog-2", "check for assigned work", "ga-wisp-new", iso_z(T0 + timedelta(minutes=6)))], [])
    s2 = e.run(T0 + timedelta(minutes=7), bootstrap="tail")
    ok("...but a nudge that appears afterwards is", s2["new"] == 1, str(s2))


with_env(t_nudge_bootstrap)

# ---------------------------------------------------------------------------------------------
print("-- 9. run budget, lock, unparseable events --")


def t_cap(e: Env):
    e.write_events([ev_mail(i, T0 + timedelta(seconds=i), f"c{i}", "gastown.mayor", f"Beads sem rota {i}", "x") for i in range(1, 8)])
    s = e.run(T0 + timedelta(minutes=5), max_per_run=3)
    ok("MAX_PER_RUN bounds the work of one run", s["new"] == 3, str(s))
    s2 = e.run(T0 + timedelta(minutes=6), max_per_run=3)
    s3 = e.run(T0 + timedelta(minutes=7), max_per_run=3)
    ok("the backlog drains over later runs, nothing skipped, nothing repeated", (s2["new"], s3["new"]) == (3, 1)
       and sorted(json.loads(e.state.read_text())["pending"]) == sorted(f"mail:c{i}" for i in range(1, 8)))


with_env(t_cap)


def t_lock(e: Env):
    """Catches: launchd/gc-order stacking instances (ga-y0g5x: 4 concurrent guards took `bd` down)."""
    e.write_events([ev_mail(1, T0, "l1", "gastown.mayor", "Beads sem rota", "x")])
    lock = e.state.parent / "portaria-shadow.lock"
    lock.mkdir(parents=True, exist_ok=True)
    (lock / "pid").write_text(str(os.getpid()))          # a LIVE pid holds it
    s = e.run(T0 + timedelta(minutes=5))
    ok("a live instance holds the lock -> this run does nothing", s.get("skipped") == "locked" and not e.state.exists(), str(s))
    (lock / "pid").write_text("999999")                    # a dead pid
    s2 = e.run(T0 + timedelta(minutes=6))
    ok("a stale lock (dead pid) is reclaimed", s2.get("new") == 1, str(s2))
    ok("the lock is released after a run", not lock.exists())


with_env(t_lock)


def t_junk_events(e: Env):
    """Catches: one corrupt line / a mail event without a recipient (13 such in 40h) must not kill the run."""
    lines = [json.dumps(ev_mail(1, T0, "k1", "gastown.mayor", "Beads sem rota", "x")), "{not json",
             json.dumps({"seq": 2, "type": "mail.sent", "ts": iso_local(T0), "actor": "x", "subject": "?", "payload": {"message": {"id": "nb", "subject": ""}}}),
             json.dumps(ev_mail(3, T0, "k3", "gastown.mayor", "Beads sem rota", "y"))]
    e.events.write_text("\n".join(lines) + "\n")
    s = e.run(T0 + timedelta(minutes=5))
    ok("corrupt line + recipient-less mail are skipped, the good ones observed", s["new"] == 2 and s["unparseable"] >= 1, str(s))


with_env(t_junk_events)

# ---------------------------------------------------------------------------------------------
print("-- 9b. bd reads: a missing bead is data, an infra failure trips the breaker --")


def t_bd_not_found(e: Env):
    """Catches (gate ga-aijm2v.4, low): the reader matched only "no issue found", but the real
    `bd show <missing> --json` prints {"error": "no issues found matching the provided IDs"}
    (verified live 26/09; `bd comments` says "no issue found matching ..."). A missing bead was
    counted as an INFRA failure, and three in a row (deleted/merged beads are routine) tripped the
    breaker so the rest of the run read nothing — every later delivery came out 'deferred'."""
    real = {"show": '{"error": "no issues found matching the provided IDs", "schema_version": 1}',
            "comments": '{"error": "resolving ga-x: no issue found matching \\"ga-x\\"", "schema_version": 1}'}
    rd = ps.BdReader(e.cfg(), lambda rig, args: (1, real[args[0]]))
    for i in range(4):
        rd.facts(f"ga-gone{i}a")
    ok("four missing beads via `bd show` (the plural wording) do not trip the breaker", rd.fail_streak == 0, f"streak={rd.fail_streak}")
    for i in range(4):
        rd.comments(f"ga-gone{i}b")
    ok("...nor via `bd comments` (the singular wording)", rd.fail_streak == 0, f"streak={rd.fail_streak}")
    ok("so the next read is still attempted (not DEFERRED)", rd.comments("ga-live1") is not ps.DEFERRED)
    ok("a missing bead's comments are 'unavailable' (None), never an empty list", rd.comments("ga-gone0b") is None)
    boom = ps.BdReader(e.cfg(), lambda rig, args: (1, ""))
    for i in range(3):
        boom.comments(f"ga-down{i}a")
    ok("CONTROL: three real failures (rc=1, no output) DO trip it", boom.comments("ga-down9z") is ps.DEFERRED)


with_env(t_bd_not_found)

print("-- 10. rig routing for `bd -C` --")
with tempfile.TemporaryDirectory() as td:
    tdp = Path(td)
    (tdp / "city.toml").write_text('[[rigs]]\nname = "whatsapp_automation"\nprefix = "wa"\n[[rigs]]\nname = "property_scrapers"\nprefix = "ps"\n')
    (tdp / ".gc").mkdir()
    # the REAL .gc/site.toml uses [[rig]] (singular) — a fixture that guessed [[rigs]] hid an empty map live
    (tdp / ".gc" / "site.toml").write_text('workspace_name = "x"\n[[rig]]\nname = "whatsapp_automation"\npath = "/x/wa"\n[[rig]]\nname = "property_scrapers"\npath = "/x/ps"\n')
    m = ps.load_rig_paths(tdp)
    ok("prefix -> path from city.toml + .gc/site.toml, HQ prefix 'ga' -> the city itself",
       m == {"wa": "/x/wa", "ps": "/x/ps", "ga": str(tdp)}, str(m))
    ok("unknown prefix has no path (facts unavailable, never guessed)", ps.rig_for_entity("zz-abc12", m) is None and ps.rig_for_entity("wa-abc12", m) == "/x/wa")

# ---------------------------------------------------------------------------------------------
print("-- 11. the report understands the Portaria and does not mix it into the suppression numbers --")
spec_r = importlib.util.spec_from_file_location("jev_experiment_report", HERE / "jev_experiment_report.py")
rep = importlib.util.module_from_spec(spec_r)
sys.modules["jev_experiment_report"] = rep
spec_r.loader.exec_module(rep)


def prec(classe, c1, c2, casc, desf, dest="gastown.mayor", tin=400, tout=30, jev_ok=True):
    return {"ts": "2026-09-25T18:00:00Z", "mode": "portaria", "experiment": f"portaria-{classe}", "classe": classe, "canal": "mail",
            "destinatario": dest, "camada1": c1, "camada2": c2, "cascata": casc, "desfecho": desf,
            "jev_ok": jev_ok, "jev_tokens_in": tin, "jev_tokens_out": tout}


events = [
    prec("gate-held", "pular", "seguir", "pular", "nao_agiu"),
    prec("gate-held", "seguir", "pular", "pular", "agiu"),          # Jev-only skip, recipient acted = GRAVE
    prec("gate-held", "pular", "pular", "pular", "nao_sei"),        # skipped, outcome unknown = uncertain, never 'safe'
    prec("gate-held", "seguir", "seguir", "seguir", "agiu"),
    prec("gate-held", "seguir", "nao_sei", "seguir", "nao_agiu", jev_ok=False, tin=0, tout=0),
    {"experiment": "mayor-inbox", "arm": "control", "suppress": False, "jev_ok": False, "jev_tokens_in": 0, "jev_tokens_out": 0},
]
sup = rep.summarize(events)
ok("portaria events never enter the suppression-experiment summary (they have no arm/suppress)", list(sup) == ["mayor-inbox"], str(list(sup)))
pt = rep.summarize_portaria(events)["gate-held"]
ok("volume = 5", pt["volume"] == 5, str(pt))
ok("measurable share: 4 of 5 outcomes are agiu/nao_agiu, 1 is nao_sei", pt["desfecho_conclusivo"] == 4, str(pt))
ok("rule would skip 2 (camada1=pular), Jev would skip 2 (camada2=pular), cascade skips 3",
   (pt["regra_pularia"], pt["jev_pularia"], pt["cascata_pularia"]) == (2, 2, 3), str(pt))
ok("GRAVE error = skipped by the cascade AND the recipient acted: exactly 1", pt["erro_grave"] == 1, str(pt))
ok("...Jev-only grave error is counted apart", pt["erro_grave_jev"] == 1 and pt["erro_grave_regra"] == 0, str(pt))
ok("skipped with outcome 'nao_sei' is 'incerto', never folded into safe or grave", pt["pularia_incerto"] == 1 and pt["pularia_seguro"] == 1, str(pt))
ok("Jev-unavailable deliveries are counted apart (third state)", pt["jev_indisponivel"] == 1, str(pt))
ok("Jev's real cost is summed", pt["jev_tokens_in"] == 1600 and pt["jev_tokens_out"] == 120, str(pt))
m = rep._portaria_metrics(pt, {"gastown.mayor": 300000})
ok("tokens saved (ESTIMATED) = safe skips x measured cache-read per turn of the recipient - Jev cost",
   m["tokens_economizados"] == 1 * 300000 - 1600 - 120, str(m))
m2 = rep._portaria_metrics(pt, {})
ok("recipient with no measured cache-read -> tokens saved is None ('nao medido'), never a made-up number", m2["tokens_economizados"] is None, str(m2))
txt = rep.format_report(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={"gastown.mayor": 300000})
ok("the full report prints the Portaria block with the grave-error line",
   "portaria-gate-held" in txt and "erro grave" in txt.lower(), txt[-400:])
pt_txt = rep.format_resumo_pt(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={"gastown.mayor": 300000})
pt0 = dict(pt, pularia_seguro=0, seguro_por_destinatario={})
ok("no safe skips -> the report says nothing was saved yet, never a negative 'saved' number",
   "none yet" in rep.format_report(sup, {}, "t", portaria_summary={"x": pt0}, cache_read_by_recipient={})
   and "nenhum pulo seguro ainda" in rep.format_resumo_pt(sup, {}, "t", portaria_summary={"x": pt0}, cache_read_by_recipient={}))
ok("the daily ntfy (pt) carries volume, skip %, and grave errors", "Portaria" in pt_txt and "erro grave" in pt_txt.lower(), pt_txt[-500:])

# transcripts -> measured cache-read per API call (read-only; the report's token estimate rests on it)
with tempfile.TemporaryDirectory() as td:
    proj = Path(td)
    mdir = proj / "-Users-athos-gt--gascity-gastown-hq--gc-agents-mayor"
    mdir.mkdir()
    now_z = datetime.now(timezone.utc)

    def tline(rid, cache, when):
        return json.dumps({"type": "assistant", "requestId": rid, "timestamp": when.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                           "message": {"usage": {"cache_read_input_tokens": cache}}})
    (mdir / "s1.jsonl").write_text("\n".join([
        tline("r1", 100000, now_z - timedelta(hours=1)),
        tline("r1", 100000, now_z - timedelta(hours=1)),        # same API request, second content block: counted ONCE
        tline("r2", 300000, now_z - timedelta(hours=2)),
        tline("old", 900000, now_z - timedelta(hours=40)),      # outside the 24h window
        "not json at all", json.dumps({"type": "user", "message": {"content": "hi"}}),
    ]) + "\n")
    got = rep.measure_cache_read({"gastown.mayor", "someone-unmapped"}, since_hours=24, projects_dir=proj)
    ok("mean cache-read per API call: (100000+300000)/2, request counted once, old request excluded", got["gastown.mayor"] == 200000, str(got))
    ok("a recipient whose transcripts cannot be located is None (never a made-up number)", got["someone-unmapped"] is None, str(got))
    ok("a mapped recipient with no transcript dir is None", rep.measure_cache_read({"gastown.dog-9"}, projects_dir=proj)["gastown.dog-9"] is None)

# --- gate low-medium: a Portaria row is filed under the day its outcome was MEASURED ---------------
# Catches: jev-daily-report.sh reports `--date <yesterday>` at 00:07Z, filtering by the row's `ts`
# (the DELIVERY time). A delivery stamped 23:05Z-24:00Z is resolved >= 62 min later — after that report
# already ran — so it belonged to a day that had been reported and was in no later day's report either.
with tempfile.TemporaryDirectory() as td:
    logp = Path(td) / "jev.jsonl"
    late = dict(prec("gate-held", "seguir", "seguir", "seguir", "nao_agiu"), ts="2026-09-25T23:30:00Z", resolved_at="2026-09-26T00:35:00Z")
    early = dict(prec("gate-held", "seguir", "seguir", "seguir", "agiu"), ts="2026-09-25T10:00:00Z", resolved_at="2026-09-25T11:05:00Z")
    other = {"ts": "2026-09-25T23:50:00Z", "experiment": "mayor-inbox", "arm": "control", "suppress": False, "jev_ok": False}
    nodate = dict(prec("gate-held", "seguir", "seguir", "seguir", "agiu"), ts="2026-09-25T09:00:00Z")  # no resolved_at: falls back to ts
    logp.write_text("".join(json.dumps(r) + "\n" for r in (late, early, other, nodate)), encoding="utf-8")
    old_log = rep.JEV_LOG
    rep.JEV_LOG = logp
    try:
        d25 = rep.load_events("2026-09-25", None)
        d26 = rep.load_events("2026-09-26", None)
    finally:
        rep.JEV_LOG = old_log
    ok("a delivery at 23:30Z resolved at 00:35Z the next day is in the NEXT day's report...",
       [r for r in d26 if r.get("mode") == "portaria"] == [late], str(d26))
    ok("...and NOT in the day of its delivery (it is in exactly one daily report)", late not in d25, str(d25))
    ok("a portaria row that has no resolved_at falls back to its own ts", nodate in d25)
    ok("non-portaria rows are still filed by their own ts (suppression experiment untouched)", other in d25 and other not in d26)

# --- the pending line: "N observed, outcome not measured yet" ---------------------------------------
ptxt = rep.format_report(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={}, portaria_pending=3)
ok("the report says how many observed deliveries still wait for their outcome", "not yet measured: 3" in ptxt, ptxt[-300:])
ok("a state file that cannot be read shows n/d, never 0",
   "not yet measured: n/d" in rep.format_report(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={}, portaria_pending=None))
ok("a caller that did not ask for it gets no pending line", "not yet measured" not in rep.format_report(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={}))
ok("the ntfy (pt) carries it too", "Ainda sem desfecho: 3" in rep.format_resumo_pt(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={}, portaria_pending=3))
ok("...and n/d when unreadable", "Ainda sem desfecho: n/d" in rep.format_resumo_pt(sup, {}, "t", portaria_summary={"gate-held": pt}, cache_read_by_recipient={}, portaria_pending=None))
with tempfile.TemporaryDirectory() as td:
    sf = Path(td) / "state.json"
    os.environ["PORTARIA_STATE_FILE"] = str(sf)
    try:
        ok("no state file -> None (cannot tell), never 0", rep.load_portaria_pending() is None)
        sf.write_text(json.dumps({"pending": {"mail:a": {}, "mail:b": {}}}))
        ok("the count is the size of the state's pending map", rep.load_portaria_pending() == 2)
        sf.write_text(json.dumps({"pending": {}}))
        ok("an empty pending map is a real 0", rep.load_portaria_pending() == 0)
        # Catches: valid JSON of the WRONG SHAPE is the "odd" state the docstring promises is never a 0 —
        # the corrupt-file case below goes through the except branch, so only these reach the `else None`.
        sf.write_text(json.dumps({"cursor_seq": 3}))
        ok("valid JSON with no pending map (odd state) -> None, never 0", rep.load_portaria_pending() is None)
        sf.write_text(json.dumps({"pending": []}))
        ok("a pending of the wrong type -> None, never 0", rep.load_portaria_pending() is None)
        sf.write_text(json.dumps([1, 2]))
        ok("valid JSON that is not even an object -> None", rep.load_portaria_pending() is None)
        sf.write_text("{ not json")
        ok("a corrupt state file -> None", rep.load_portaria_pending() is None)
        ok("...and reading it does not set the file aside (the report is read-only)", sf.exists() and sf.read_text() == "{ not json"
           and not list(Path(td).glob("state.json.*")), str(list(Path(td).iterdir())))
    finally:
        os.environ.pop("PORTARIA_STATE_FILE", None)

# --- the label must not claim more than the outcome measures ----------------------------------------
ok("the safe-skip label says 'no action SEEN', not that the recipient certainly did nothing",
   "did NOT act" not in ptxt and "no action SEEN" in ptxt and "destinatario nao agiu" not in pt_txt, ptxt[-500:])

# ---------------------------------------------------------------------------------------------
print("-- 12. wiring: order present, F1 order gone, exec script exists --")
PACK = HERE.parent / "packs" / "town-deltas"
order = PACK / "orders" / "portaria-shadow.toml"
ok("orders/portaria-shadow.toml exists", order.exists())
if order.exists():
    txt = order.read_text()
    ok("it is a cooldown order that execs the pack script", 'trigger = "cooldown"' in txt and 'exec = "$PACK_DIR/assets/scripts/portaria-shadow.sh"' in txt)
ok("the pack script exists and is executable", (PACK / "assets" / "scripts" / "portaria-shadow.sh").exists() and os.access(PACK / "assets" / "scripts" / "portaria-shadow.sh", os.X_OK))
ok("F1's order (mayor-inbox-jev-triage) is switched OFF — the Portaria replaces it", not (PACK / "orders" / "mayor-inbox-jev-triage.toml").exists())
f1 = (PACK / "assets" / "scripts" / "mayor-inbox-jev-triage.sh").read_text()
ok("F1's script header carries the note explaining the replacement", "ga-aijm2v.4" in f1 and "SUBSTITU" in f1.upper().split("set -euo pipefail")[0])

print("-- 13. the order's entry point (portaria-shadow.sh): exit code, log line, hard timeout --")
import subprocess
WRAP = PACK / "assets" / "scripts" / "portaria-shadow.sh"
with tempfile.TemporaryDirectory() as td:
    tdp = Path(td)
    fake_ok = tdp / "fake-py-ok"
    fake_ok.write_text('#!/bin/sh\necho "portaria-shadow: {\\"new\\": 2}"\nexit 0\n'); fake_ok.chmod(0o755)
    fake_bad = tdp / "fake-py-bad"
    fake_bad.write_text('#!/bin/sh\necho boom >&2\nexit 3\n'); fake_bad.chmod(0o755)
    fake_slow = tdp / "fake-py-slow"
    fake_slow.write_text('#!/bin/sh\nsleep 30\n'); fake_slow.chmod(0o755)
    logf = tdp / "run.log"

    def wrap(py, timeout="270"):
        return subprocess.run(["bash", str(WRAP)], capture_output=True, text=True, timeout=60,
                              env={"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "PORTARIA_PYTHON": str(py),
                                   "PORTARIA_SCRIPT": "ignored.py", "PORTARIA_LOG_FILE": str(logf), "PORTARIA_TIMEOUT_S": timeout})
    r = wrap(fake_ok)
    ok("success: exit 0, the run's summary is echoed and logged with rc=0", r.returncode == 0 and '"new": 2' in r.stdout and "rc=0" in logf.read_text())
    r = wrap(fake_bad)
    ok("a failing run propagates its exit code (so `gc order` records order.failed) and logs rc=3", r.returncode == 3 and "rc=3" in logf.read_text())
    r = wrap(fake_slow, timeout="1")
    ok("a hung run is killed by the wrapper's timeout (rc=124) and says TIMEOUT — the lock is then reclaimable", r.returncode == 124 and "TIMEOUT" in logf.read_text())

print(f"\nportaria-shadow selftest: PASS={PASS} FAIL={FAIL}")
sys.exit(1 if FAIL else 0)
