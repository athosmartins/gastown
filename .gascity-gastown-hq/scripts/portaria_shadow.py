#!/usr/bin/env python3
"""portaria_shadow.py (ga-aijm2v.4) — Portaria do Jev v1, modo SOMBRA.

WHY: every message delivered to an agent (mail or nudge) wakes it, even when there is nothing
to do — a turn that re-reads hundreds of thousands of cached tokens (measured 25/09: 7.2 BILLION
cache-read tokens vs 24.5 M output in 24h; 5 of 8 of the Mayor's mails needed no action). The
Portaria asks, for each delivery, "does this need to wake the recipient?" — with a cascade:

  camada 1  fixed rule (free): duplicate of the same alert, protected classes, a bead the pool
            already owns
  camada 2  Jev (Cloudflare Workers AI, ~500 tokens): ONE call, three questions about the
            message + the LIVE facts of the cited bead (status/assignee/labels/routing)
  camada 3  Claude: what 1-2 did not settle falls through to the recipient — which is exactly
            what happens today. v1 only RECORDS that ("acordaria"); it never runs a model.

SHADOW: nothing about a delivery changes. The only external commands are two `bd` READS
(show / comments — default_bd_runner refuses every other subcommand). No `gc mail archive`, no
nudge, no label. It writes ONE line per delivery to the experiment log (JEV_EXPERIMENT_LOG,
experiment "portaria-<classe>") once the outcome is known.

THE OUTCOME ("desfecho") — AND WHY THE SPEC'S PREMISE COULD NOT BE USED AS WRITTEN:
The bead proposed "the recipient acted = an events.jsonl event with actor = recipient
(bead.updated/closed/created, sling, mail reply)". Measured 25/09 over the last archive
(44 402 events): EVERY bead.* event (24 508 of them) carries actor "cache-reconcile". No bead
event says who acted. Taken literally that would score every bead action as "the recipient did
not act", make skipping look free, and hide exactly the false negatives the experiment exists
to count. So the outcome uses only what IS attributable, with three honest states:

  agiu      positive, attributable evidence inside the window (default 60 min after delivery):
            a bead comment AUTHORED by the recipient on a cited entity (bd comments), a mail
            SENT by the recipient (events actor) citing an entity, or a reply by the recipient
            on the same mail thread.
  nao_agiu  no such evidence AND nobody touched any cited entity in the window: ZERO bead.*
            events, ZERO comments (by anyone), the comments channel and the events read whole.
            It claims exactly that — no action SEEN on the cited entity(ies). It is NOT a proof
            the recipient did nothing: nudging a crew, acting on another bead or editing code
            leaves no trace here.
  nao_sei   everything else: no identifiable entity; comments unreadable (bd/Dolt down — never
            read as "no comments"); the entity changed but no event names who (automation and
            agents look identical); a comment by an author that is not the recipient (see
            below); events unreadable in the window (a truncated/corrupt archive — never read
            as "no events"); the events file does not yet cover the window (then the delivery
            simply stays pending).

A CITED BEAD THAT bd SAYS DOES NOT EXIST (ga-aijm2v.11): not an entity of the delivery, and not an
unreadable channel either. Every gate-review nudge carries the boilerplate id "ga-p5q3" — a bead that
no longer exists — so treating "no issue found" like a failed read made the whole delivery nao_sei
(measured 26/09: 62 of 171 real rows; re-measured on 254 nudges: 219 of 254 = 86% "comentarios
ilegiveis" before, 4 after). BdReader now returns NOT_FOUND for bd's explicit "no issue found" and None
for everything that is merely a failed read (rc!=0, timeout, locked, garbled, unknown rig, wisp). The
outcome is drawn over the LIVE ids only; the log line keeps what was cited (`entidades`) and which of
those bd declared gone (`entidades_inexistentes`). Two limits keep this from becoming a way to lose
information: (1) if no cited id is left, the outcome stays nao_sei — a dead bead is nothing to
measure, never "nobody acted"; (2) POSITIVE evidence still counts through a dead id (a mail the recipient
sent citing it is still an "agiu"), because a missed action is the error that hides real alarms.
KNOWN LIMIT: "gone" is the answer of the store the id's PREFIX maps to (rig_for_entity); a bead that lives
in another store under a foreign prefix would read as gone. Measured 26/09: of 142 ids gone by that rule
(254 real nudges), each re-asked in every other registered store — 0 exist elsewhere; the rig map has
no colliding prefix today. Revisit if a prefix ever maps to a store that does not own its beads.

WHY A COMMENT BY SOMEONE ELSE IS nao_sei, NOT "the recipient did not act" (gate ga-aijm2v.4 #1):
comment authors are NOT reliable identities. Measured 25/09 over 156 beads: 'Test' (bd's git-user
fallback when BD_ACTOR is unset — agents' comments land there too) ~1140 of ~1800, 'automation'
248, and the Mayor under TWO spellings ('gastown.mayor' 207, 'gastown__mayor' 50; 170 of 178 real
nudge recipients match no observed author at all). A comment inside the window whose author is not
positively the recipient may be the recipient. Comments emit no bead.* event, so nothing else
catches it. The same distrust does NOT apply to mail: measured over 43 archives + the live file
(~8.6k mail.sent), agents send mail under their OWN name (gastown.mayor 318, the dogs, every crew),
and `human`/`controller` are daemons — so a mail from another named actor is attributable.

mail.read / mail.archived by the recipient is deliberately NOT an action: it proves the wake
happened, not that the message needed it (the Mayor archives ~everything it reads).

The daily report (jev_experiment_report.py) counts a "grave error" only over `agiu`: a delivery
the cascade would have skipped that the recipient then acted on. `nao_sei` among skips is shown
apart as "incerto" — never folded into safe or grave. Grave errors are therefore a LOWER bound;
the report says so.

THIRD STATE, everywhere: Jev down / timing out / answering garbage / skipping the primary
question is "nao_sei" and never "pular". After 3 consecutive Jev failures in one run the rest of
the run's deliveries are recorded "nao_sei" (circuit_open) without more calls.

WHAT IT OBSERVES: mail.sent events (events.jsonl + rotated .gz archives, cursor by seq) and new
items in the nudge queue (.gc/nudges/state.json `pending`, by id — nudges do not become events).
Activation (bootstrap=tail, the default): only deliveries AFTER the first run are recorded —
backfilling history would feed Jev today's bead state as if it were the state at delivery time.
The nudge queue is sampled per run, so a nudge enqueued and delivered between two runs is not
seen (the report says nudge coverage is by snapshot).

RUNS: `gc order` (orders/portaria-shadow.toml, cooldown 5m), single instance (mkdir lock),
bounded (MAX_PER_RUN deliveries — each costs one ~2-5 s Jev call, so a full run is ~1-2 min —,
bd call budget, the wrapper's timeout), idempotent (cursor + resolved ledger + the
log's own tail), atomic state writes.

CLI:  python3 portaria_shadow.py [run|status]     env: see config_from_env()
"""
from __future__ import annotations

import gzip
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import tomllib
import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as jev  # noqa: E402  (sibling module: call_jev_multi + JEV_LOG)

UTC = timezone.utc
DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
ALLOWED_BD = frozenset({"show", "comments"})  # the ONLY bd subcommands this consumer may run
MAX_ENTITIES = 6
TAIL_BYTES = 512 * 1024

# ── classification ─────────────────────────────────────────────────────────────────────────
# (classe, subject regex, protegida, entity_from). Subjects copied from ~40h of the Mayor's REAL
# mail (events.jsonl, 24-25/09) — not guessed. `protegida` = an explicit decision request or a
# critical escalation: deduping it or asking Jev to suppress it would defeat the mechanism that
# produced it, so it is only ever observed. entity_from says WHICH ids of the message are the
# thing the alert is about (bodies also carry boilerplate references — "ga-l8yh6, follow-up of
# ga-d3eg2" is in every orphan-label alert and is NOT a flagged bead):
#   "subject"  the FIRST id of the subject ("Gate held for daemon verification: wa-1 (ga-l7n3v)" -> wa-1;
#              the parenthesised id is the mechanism, not the subject of the alert)
#   "list"     ids opening the indented lines of the "NEW/DUE" section of a watchdog body
#   "sem-rota" ids before " Ver " in a "Beads sem rota" body (what follows are references)
#   "none"     class-level alert with no entity (its outcome is always nao_sei: nothing to attribute to)
MAIL_CLASSES = [
    ("decisao-pendente", r"^Decis[ãa]o pendente:", True, "subject"),
    ("escalation", r"^(ESCALATION:|Gate escalation:)", True, "subject"),
    ("capacidade", r"^Capacidade:", True, "subject"),
    ("town-root-diverged", r"^Gas City: town root diverged", True, "subject"),
    ("disk-floor", r"^Dolt disk-floor (CRITICAL|RECOVERED)", False, "none"),
    ("gate-held", r"^(Gate held for|Your gate PASS is held for)", False, "subject"),
    ("gate-orphan-label", r"^Watchdog: \d+ bead\(s\) com gate:\*", False, "list"),
    ("gate-marker-missing", r"^Watchdog: \d+ gate marker/run\(s\) missing", False, "list"),
    ("gate-needs-rebase", r"^Gate: marker \S+ preso em needs-rebase", False, "subject"),
    ("gate-author-unreachable", r"^Gate: author unreachable for", False, "subject"),
    ("gate-stale-marker", r"^Gate: stale marker skipped", False, "subject"),
    ("gate-fail", r"^(Gate FAIL|QUALITY GATE FAILED)", False, "subject"),
    ("city-health-sentinel", r"^\[city-health-sentinel\]", False, "none"),
    ("beads-sem-rota", r"^Beads sem rota", False, "sem-rota"),
    ("agente-ocioso-travado", r"^Agente (ocioso|travado)", False, "subject"),
    ("daemon-presence", r"^Daemon-presence:", False, "none"),
]
# Nudges that CARRY the task itself (a review to perform, a story to refine, a failure to fix)
# are work orders, not notifications: observed, never evaluated.
NUDGE_CLASSES = [
    ("nudge-check-work", r"^check for assigned work", False),
    ("nudge-gate-review", r"^QUALITY GATE REVIEW", True),
    ("nudge-refino-gate", r"^REFINO QUALITY GATE", True),
    ("nudge-auto-refino", r"^AUTO-REFINO", True),
    ("nudge-gate-failed", r"^QUALITY GATE FAILED", True),
    ("nudge-gate-retry", r"^Gate auto-retry", False),
    ("nudge-gate-passed", r"^Your branch .* has passed guard", False),
]
# Classes whose alert is moot once the cited bead is already gate:needs-fix AND routed to a pool.
POOL_ROUTED_CLASSES = frozenset({"gate-author-unreachable", "gate-fail"})
NEVER_RULE_SKIP = frozenset({"outros", "nudge-outros"})  # unknown = never skipped by a rule

# `(?!worker\b)`: "wa-worker", "ps-worker-2" are pool/session names that appear in nudges and branch
# names ("crew/wa-worker/wa-xyz"), not beads (seen live 25/09: every gate-review nudge "cited" wa-worker).
ENTITY_RE = re.compile(r"\b(?:ga|wa|ps|dc|gt|lx|ma)-(?!worker\b)(?:wisp-)?[a-z0-9]{3,}(?:\.[0-9]+)*\b")

QUESTIONS = {
    "precisa_agir": (
        "Esta mensagem foi entregue a um agente autonomo (o destinatario), que precisaria gastar um turno "
        "inteiro para le-la. Considere tambem os FATOS VIVOS do bead citado. O destinatario precisa AGIR "
        "agora (investigar, decidir, alterar algo) por causa dela, ou pode ignora-la sem prejuizo?",
        "Precisa agir agora -- problema real e novo que ninguem mais esta tratando",
        "Pode ignorar -- rotina, repeticao, ja tratado por outro, ou nada a fazer",
    ),
    "duplicata": (
        "Esta mensagem repete algo que o destinatario ja recebeu, ja conhece ou que ja foi resolvido?",
        "E repeticao / ja conhecido / ja resolvido",
        "E informacao nova",
    ),
    "resolve_sozinho": (
        "O proprio sistema (watchdog, gate, pool de workers, ciclo seguinte) resolve isto sem que o "
        "destinatario faca nada?",
        "Resolve sozinho no proximo ciclo",
        "Precisa de alguem agindo",
    ),
}
PRIMARY_Q = "precisa_agir"
EXTRA_Qs = ("duplicata", "resolve_sozinho")


# ── config ─────────────────────────────────────────────────────────────────────────────────
@dataclass
class Config:
    city: Path
    events_file: Path
    nudge_state: Path
    state_file: Path
    jev_log: Path
    janela_min: int = 60
    grace_s: int = 120
    confidence: float = 0.85
    max_per_run: int = 30
    dup_window_min: int = 120
    bootstrap: str = "tail"  # "tail": record only what arrives after activation | "start": the whole live file
    rig_paths: dict = field(default_factory=dict)
    jev_fail_limit: int = 3
    bd_fail_limit: int = 3
    max_bd_calls: int = 80
    state_text_max: int = 3000
    bd_timeout_s: int = 20
    # events unreadable while measuring a window (a truncated archive, a rotation racing the read):
    # keep the delivery pending this long past its window closing — the next run usually reads it
    # whole — then settle it as nao_sei (never nao_agiu) so a permanently bad archive cannot wedge it
    unreadable_retry_min: int = 120


def load_rig_paths(city: Path) -> dict:
    """bead-id prefix -> rig path, for `bd -C`. Prefixes live in city.toml, paths in .gc/site.toml,
    joined by rig name. The HQ prefix is 'ga' and its path is the city itself. Nothing is guessed:
    an unknown prefix simply has no path (the entity's facts/comments are then unavailable)."""
    prefixes: dict = {}
    paths: dict = {}
    try:
        for r in tomllib.loads((city / "city.toml").read_text(encoding="utf-8")).get("rigs", []):
            if r.get("name") and r.get("prefix"):
                prefixes[r["name"]] = r["prefix"]
    except (OSError, tomllib.TOMLDecodeError):
        pass
    try:
        site = tomllib.loads((city / ".gc" / "site.toml").read_text(encoding="utf-8"))
        # the REAL file uses [[rig]] (singular); [[rigs]] is what city.toml uses — read both so the
        # map never silently comes back empty (which made every outcome nao_sei, seen live 25/09)
        for r in (site.get("rig") or []) + (site.get("rigs") or []):
            if r.get("name") and r.get("path"):
                paths[r["name"]] = r["path"]
    except (OSError, tomllib.TOMLDecodeError):
        pass
    out = {prefix: paths[name] for name, prefix in prefixes.items() if name in paths}
    out["ga"] = str(city)
    return out


def rig_for_entity(entity: str, rig_paths: dict):
    return rig_paths.get(entity.split("-", 1)[0])


def config_from_env() -> Config:
    e = os.environ.get
    city = Path(e("GC_CITY_PATH") or DEFAULT_CITY)
    state_dir = Path(e("GC_PACK_STATE_DIR") or (Path(e("GC_CITY_RUNTIME_DIR") or city / ".gc" / "runtime") / "packs" / "maintenance"))
    return Config(
        city=city,
        events_file=Path(e("PORTARIA_EVENTS_FILE") or city / ".gc" / "events.jsonl"),
        nudge_state=Path(e("PORTARIA_NUDGE_STATE") or city / ".gc" / "nudges" / "state.json"),
        state_file=Path(e("PORTARIA_STATE_FILE") or state_dir / "portaria-shadow-state.json"),
        jev_log=Path(e("JEV_EXPERIMENT_LOG") or jev.JEV_LOG),
        janela_min=int(e("PORTARIA_JANELA_MIN", "60")),
        confidence=float(e("PORTARIA_CONFIDENCE", "0.85")),
        max_per_run=int(e("PORTARIA_MAX_PER_RUN", "30")),
        dup_window_min=int(e("PORTARIA_DUP_WINDOW_MIN", "120")),
        bootstrap=e("PORTARIA_BOOTSTRAP", "tail"),
        unreadable_retry_min=int(e("PORTARIA_UNREADABLE_RETRY_MIN", "120")),
        rig_paths=load_rig_paths(city),
    )


# ── small helpers ──────────────────────────────────────────────────────────────────────────
def parse_ts(s):
    if not s or not isinstance(s, str):
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def ts_z(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def classify_mail(subject: str):
    for classe, rx, protegida, entity_from in MAIL_CLASSES:
        if re.search(rx, subject or ""):
            return classe, protegida, entity_from
    return "outros", False, "subject"


def classify_nudge(message: str):
    for classe, rx, protegida in NUDGE_CLASSES:
        if re.search(rx, (message or "").strip()):
            return classe, protegida
    return "nudge-outros", False


def extract_entities(text: str) -> list:
    seen: list = []
    for m in ENTITY_RE.findall(text or ""):
        if m not in seen:
            seen.append(m)
    return seen


# `(?=\s|$)`: the block is "\n".join(lines) with NO trailing newline, so an id that ends the block
# (the last line of the section is just "  wa-zzz99") has no whitespace after it — `(?=\s)` alone
# silently dropped exactly that id (gate ga-aijm2v.4, low)
_LIST_ID_RE = re.compile(r"^[ \t]{2,}(" + ENTITY_RE.pattern + r")(?=\s|$)", re.M)


def entities_from(entity_from: str, subject: str, body: str) -> list:
    if entity_from == "subject":
        return extract_entities(subject)[:1]
    if entity_from == "sem-rota":
        return extract_entities((body or "").split(" Ver ")[0])
    if entity_from == "list":
        head, sep, rest = (body or "").partition("NEW/DUE")
        if not sep:
            return []
        # the section is the run of lines after the "NEW/DUE (n) — why..." header line, up to a blank line
        lines = rest.split("\n")[1:]
        block = []
        for ln in lines:
            if not ln.strip():
                break
            block.append(ln)
        return [m.group(1) for m in _LIST_ID_RE.finditer("\n".join(block))]
    return []


def _durable(ids: list) -> list:
    """Outcome/dup entities exclude ephemeral wisps (`*-wisp-*`): no comment channel to read, and a
    nudge's bead_id is almost always one — naming it an entity made every nudge outcome 'unreadable'."""
    return [x for x in ids if "-wisp-" not in x]


def _read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _append_jsonl(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


# ── events (live file + rotated archives) ─────────────────────────────────────────────────
ARCHIVE_RE = re.compile(r"\.archive-(\d{8}T\d{6}Z)-seq-(\d+)-(\d+)\.gz$")


def _list_archives(events_file: Path) -> list:
    out = []
    try:
        names = sorted(events_file.parent.glob(events_file.name + ".archive-*-seq-*-*.gz"))
    except OSError:
        return out
    for p in names:
        m = ARCHIVE_RE.search(p.name)
        if not m:
            continue
        stamp = datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC)
        out.append((stamp, int(m.group(2)), int(m.group(3)), p))
    out.sort(key=lambda t: t[1])
    return out


def _iter_lines(path: Path, gz: bool, stats):
    """Parsed events of one file. A file that cannot be read to its end is COUNTED in
    stats["unreadable_files"] (the events already yielded stay valid). Callers must not read that as
    "the rest of the file had nothing": _run_locked reports the count on the run line and refuses
    to conclude "nobody touched it" from a window it read only in part. zlib.error is the corrupt-
    deflate case — it is not an OSError, and uncaught it crashed the whole run on every later run."""
    opener = gzip.open if gz else open
    try:
        with opener(path, "rt", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    if stats is not None:
                        stats["unparseable"] = stats.get("unparseable", 0) + 1
                    continue
                if isinstance(ev, dict):
                    yield ev
    except (OSError, EOFError, zlib.error):
        if stats is not None:
            stats["unreadable_files"] = stats.get("unreadable_files", 0) + 1


def iter_events(events_file: Path, since_seq=None, since_ts=None, stats=None):
    """Events newer than `since_seq` (by seq) and/or `since_ts` (by time), oldest first, from the
    rotated archives that can still hold any and then the live file. A rotation between two runs
    is why the archives matter: the cursor may point INTO an archive."""
    for stamp, _first, last, path in _list_archives(events_file):
        if since_seq is not None and last <= since_seq:
            continue
        if since_ts is not None and stamp < since_ts:
            continue
        for ev in _iter_lines(path, True, stats):
            if since_seq is not None and int(ev.get("seq") or 0) <= since_seq:
                continue
            yield ev
    for ev in _iter_lines(events_file, False, stats):
        if since_seq is not None and int(ev.get("seq") or 0) <= since_seq:
            continue
        yield ev


def _last_event(events_file: Path):
    """The last parseable event of the live file, read from its tail (the file reaches ~15 MB)."""
    try:
        size = events_file.stat().st_size
        with events_file.open("rb") as f:
            f.seek(max(0, size - 128 * 1024))
            raw = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    for line in reversed(raw.splitlines()):
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(ev, dict):
            return ev
    return None


def _events_gap(events_file: Path, cursor: int) -> int:
    """How many seqs between `cursor` and the first event still on disk are in NO file (0 = none lost)."""
    first = _first_event(events_file)
    if first is None or not isinstance(first.get("seq"), int) or first["seq"] <= cursor + 1:
        return 0
    need_from, need_to = cursor + 1, first["seq"] - 1
    covered_to = need_from - 1
    for _stamp, a_first, a_last, _p in _list_archives(events_file):
        if a_last < need_from or a_first > need_to:
            continue
        if a_first <= covered_to + 1:
            covered_to = max(covered_to, min(a_last, need_to))
    return max(0, need_to - covered_to)


def _first_event(events_file: Path):
    for ev in _iter_lines(events_file, False, None):
        return ev
    return None


# ── deliveries ─────────────────────────────────────────────────────────────────────────────
def mail_delivery(ev: dict):
    """A mail.sent event as a delivery, or None when it has no readable recipient (13 of 231 in
    the measured window — e.g. shapes with no `to`)."""
    msg = (ev.get("payload") or {}).get("message")
    if not isinstance(msg, dict):
        return None
    to = msg.get("to") or ev.get("message")
    mid = msg.get("id")
    ts = parse_ts(ev.get("ts")) or parse_ts(msg.get("created_at"))
    if not isinstance(to, str) or not to or not mid or ts is None:
        return None
    subject = msg.get("subject") or ""
    body = msg.get("body") or ""
    classe, protegida, entity_from = classify_mail(subject)
    ents = _durable(entities_from(entity_from, subject, body))
    return {
        "delivery_id": f"mail:{mid}", "canal": "mail", "destinatario": to, "aliases": [to],
        "ts": ts_z(ts), "thread_id": msg.get("thread_id") or "", "seq": ev.get("seq"),
        "subject": subject, "text": body, "classe": classe, "protegida": protegida,
        "entidades": ents[:MAX_ENTITIES],
    }


def nudge_delivery(item: dict):
    nid = item.get("id")
    agent = item.get("agent") or item.get("session_id")
    ts = parse_ts(item.get("created_at"))
    if not nid or not agent or ts is None:
        return None
    message = item.get("message") or ""
    classe, protegida = classify_nudge(message)
    ents = _durable(extract_entities(message))
    aliases = sorted({a for a in (agent, item.get("session_id")) if a})
    return {
        "delivery_id": f"nudge:{nid}", "canal": "nudge", "destinatario": agent, "aliases": aliases,
        "ts": ts_z(ts), "thread_id": "", "seq": None, "subject": message[:120].replace("\n", " "),
        "text": message, "classe": classe, "protegida": protegida, "entidades": ents[:MAX_ENTITIES],
        "wisp": item.get("bead_id") or "",
    }


# ── bd (READ ONLY) ────────────────────────────────────────────────────────────────────────
def default_bd_runner(rig_path: str, args: list, timeout: int = 20):
    """(returncode, stdout). Refuses anything but the two read subcommands BEFORE spawning — the
    Portaria is shadow mode and must never change a bead."""
    if not args or args[0] not in ALLOWED_BD:
        raise ValueError(f"portaria_shadow only reads beads; refused bd subcommand: {args[:1]}")
    if not rig_path:
        return 1, ""
    try:
        p = subprocess.run([os.environ.get("BD_BIN", "bd"), "-C", rig_path, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 124, ""
    return p.returncode, p.stdout


NOT_FOUND_RE = re.compile(r"\bno issues? found\b", re.I)  # both spellings bd uses for a missing bead
DEFERRED = object()  # a read that was NOT attempted (call budget / failure breaker) — retry next run, do not conclude anything
NOT_FOUND = object()  # bd ANSWERED "no issue found": the bead does not exist. An answer, not a failed read — never None


class BdReader:
    """bd reads with a per-run memo, a call budget and a failure breaker (Dolt is fragile: after
    `bd_fail_limit` consecutive INFRA failures this run stops asking). A bead that simply does not
    exist is data, not an infra failure, and never trips the breaker — bd words it two ways, and
    matching only one made a missing bead an infra failure (measured live 26/09): `bd show` prints
    "no issues found matching the provided IDs", `bd comments` "... no issue found matching ...".
    It is also not "could not read": a read that fails says nothing about the bead, one that says
    "no issue found" says the bead is gone — so the two come back as different values (NOT_FOUND vs
    None), because collapsing them made every delivery citing one deleted id unmeasurable (ga-aijm2v.11).
    Ephemeral wisps (`*-wisp-*`, the bead_id of most nudges) have no comment channel worth a call."""

    def __init__(self, cfg: Config, bd_fn):
        self.cfg, self.bd_fn = cfg, bd_fn
        self.calls = 0
        self.fail_streak = 0
        self._facts: dict = {}
        self._comments: dict = {}

    def _run(self, entity: str, args: list):
        """parsed JSON | NOT_FOUND (bd said the bead does not exist) | None (could not read: unknown rig,
        wisp, failed) | DEFERRED (not attempted)."""
        rig = rig_for_entity(entity, self.cfg.rig_paths)
        if rig is None or "-wisp-" in entity:
            return None
        if self.calls >= self.cfg.max_bd_calls or self.fail_streak >= self.cfg.bd_fail_limit:
            return DEFERRED
        self.calls += 1
        try:
            rc, out = self.bd_fn(rig, args)
        except ValueError:
            raise
        except Exception:  # noqa: BLE001 — a reader failure is data (unreadable), never a crash
            rc, out = 1, ""
        try:
            data = json.loads(out) if out.strip() else None
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict) and "error" in data:
            if NOT_FOUND_RE.search(str(data["error"])):
                self.fail_streak = 0
                return NOT_FOUND
            self.fail_streak += 1
            return None
        if rc != 0:
            self.fail_streak += 1
            return None
        self.fail_streak = 0
        return data

    def facts(self, entity: str):
        if entity in self._facts:
            return self._facts[entity]
        data = self._run(entity, ["show", entity, "--json"])
        if data is DEFERRED:
            return None  # facts are context for Jev, not a conclusion: go on without them, do not memoize
        if data is NOT_FOUND:
            data = None  # a bead that is gone has no facts to give
        b = data[0] if isinstance(data, list) and data else data
        facts = None
        if isinstance(b, dict):
            md = b.get("metadata") or {}
            facts = {"id": b.get("id", entity), "status": b.get("status"), "assignee": b.get("assignee") or "",
                     "labels": list(b.get("labels") or []), "routed_to": md.get("gc.routed_to") or ""}
        self._facts[entity] = facts
        return facts

    def comments(self, entity: str):
        """list of comment dicts | NOT_FOUND = bd said the bead does not exist (there is no channel to
        read; nothing to conclude from it either way) | None = could not read (NEVER [] — an
        unreadable channel is not an empty one) | DEFERRED = not attempted this run."""
        if entity in self._comments:
            return self._comments[entity]
        data = self._run(entity, ["comments", entity, "--json"])
        if data is DEFERRED:
            return DEFERRED
        result = NOT_FOUND if data is NOT_FOUND else (data if isinstance(data, list) else None)
        self._comments[entity] = result
        return result


# ── camadas 1 e 2 ─────────────────────────────────────────────────────────────────────────
def layer1(d: dict, ledger: dict, facts, cfg: Config):
    """Fixed rule. ('pular'|'seguir', regra). The ledger is updated for EVERY unprotected known
    delivery, skipped or not, so a chain of repeats stays a chain of duplicates."""
    if d["protegida"]:
        return "seguir", "protegida"
    if d["classe"] in NEVER_RULE_SKIP:
        return "seguir", None
    # Same alert = same recipient + class + cited entities. An alert that cites no entity is the same
    # alert only if its subject is the same modulo numbers ("avail=3GB" vs "avail=2GB" repeat; but
    # "CRITICAL" and "RECOVERED" are different alerts and must never dedupe into each other).
    ident = ",".join(d["entidades"]) or re.sub(r"\d+", "N", d["subject"])
    key = f'{d["destinatario"]}|{d["classe"]}|{ident}'
    now = parse_ts(d["ts"])
    last = parse_ts(ledger.get(key))
    ledger[key] = d["ts"]
    if last is not None and now is not None and timedelta(0) <= now - last <= timedelta(minutes=cfg.dup_window_min):
        return "pular", "duplicata"
    if d["classe"] in POOL_ROUTED_CLASSES and facts and "gate:needs-fix" in facts["labels"] and facts["routed_to"]:
        return "pular", "bead-ja-roteada-pro-pool"
    return "seguir", None


def build_state_text(d: dict, facts, cfg: Config) -> str:
    head = (f"Destinatario: {d['destinatario']}\nCanal: {d['canal']}  Classe: {d['classe']}\n"
            f"Assunto: {d['subject']}\n\n{d['text']}")
    head = head[: cfg.state_text_max]
    if facts:
        head += (f"\n\nFATOS VIVOS (lidos agora do bead {facts['id']}): status={facts['status']} "
                 f"assignee={facts['assignee'] or '-'} labels=[{', '.join(facts['labels'][:12])}] "
                 f"gc.routed_to={facts['routed_to'] or '-'}")
    return head


def layer2(d: dict, facts, cfg: Config, jev_fn, run: dict) -> dict:
    out = {"camada2": "nao_avaliada", "camada2_noul": None, "camada2_extras": {}, "jev_ok": False,
           "jev_noul": None, "jev_error": None, "jev_tokens_in": 0, "jev_tokens_out": 0}
    if d["protegida"]:
        return out
    out["camada2"] = "nao_sei"
    if run["jev_fail_streak"] >= cfg.jev_fail_limit:
        out["jev_error"] = f"circuit_open: {run['jev_fail_streak']} consecutive Jev failures in this run"
        return out
    try:
        r = jev_fn(build_state_text(d, facts, cfg), QUESTIONS)
    except Exception as e:  # noqa: BLE001 — never let a Jev bug become "pular" or a crashed run
        r = {"ok": False, "error": f"jev_fn raised {type(e).__name__}: {e}"}
    run["jev_calls"] += 1
    if not r.get("ok"):
        run["jev_fail_streak"] += 1
        out["jev_error"] = r.get("error") or "unknown"
        return out
    run["jev_fail_streak"] = 0
    out["jev_ok"] = True
    out["jev_tokens_in"] = int(r.get("tokens_in") or 0)
    out["jev_tokens_out"] = int(r.get("tokens_out") or 0)
    answers = r.get("answers") or {}
    out["camada2_extras"] = {k: answers[k] for k in EXTRA_Qs if k in answers}
    if PRIMARY_Q not in answers:
        out["jev_error"] = (r.get("bad") or {}).get(PRIMARY_Q) or "missing_primary_answer"
        return out
    try:
        noul = float(answers[PRIMARY_Q])
        if not 0.0 <= noul <= 1.0:
            raise ValueError(noul)
    except (TypeError, ValueError):
        out["jev_error"] = f"bad_primary_answer: {answers[PRIMARY_Q]!r}"
        return out
    out["camada2_noul"] = noul
    out["jev_noul"] = noul
    out["camada2"] = "pular" if round(1.0 - noul, 6) >= cfg.confidence else "seguir"
    return out


# ── outcome ────────────────────────────────────────────────────────────────────────────────
def _actor_key(name) -> str:
    """Comparable form of an actor/author string. The same agent shows up spelled two ways in bd
    comments ('gastown.mayor' 207x, 'gastown__mayor' 50x, measured 25/09), so equality is taken after
    folding the `__` spelling into the `.` one. Only EQUALITY of the folded forms ever means "the
    recipient": a different-looking string is never proof of a different actor (see the module
    docstring — that is why every other comment in the window is nao_sei, not "did not act")."""
    return str(name or "").strip().lower().replace("__", ".")


def gone_entities(ents: list, comments: dict) -> list:
    """The cited ids bd itself declared nonexistent (NOT_FOUND) — only bd's explicit answer, never a
    failed, timed-out or missing read (those are None / absent and stay 'could not read')."""
    return [x for x in ents if comments.get(x) is NOT_FOUND]


def compute_outcome(rec: dict, t0: datetime, t1: datetime, window_events: list, comments: dict,
                    events_complete: bool = True):
    """('agiu'|'nao_agiu'|'nao_sei', motivo). `window_events` are the mail.sent / bead.* events
    already inside [t0, t1]; `comments` maps entity -> list | None (unreadable) | NOT_FOUND (bd says
    the bead does not exist: it is not an entity of this delivery — see gone_entities — so it can
    neither make the outcome unreadable nor stand for "nobody touched it"); `events_complete`
    is False when the events file could not be read whole for this window (a truncated archive):
    positive evidence still counts, but "nobody touched it" can no longer be concluded. See the
    module docstring for what each state means and why bead.* events and comment authors cannot
    say who acted."""
    aliases = {_actor_key(a) for a in rec.get("aliases") or [rec["destinatario"]]}
    ents = rec.get("entidades") or []
    gone = gone_entities(ents, comments)
    live = [x for x in ents if x not in gone]  # the entities that exist: every NEGATIVE conclusion is drawn over these
    own_seq = rec.get("seq")

    for e in window_events:
        if e.get("type") != "mail.sent" or _actor_key(e.get("actor")) not in aliases or e.get("seq") == own_seq:
            continue
        msg = (e.get("payload") or {}).get("message") or {}
        if rec.get("thread_id") and msg.get("thread_id") == rec["thread_id"]:
            return "agiu", "resposta do destinatario na mesma thread do mail"
        # whole-id match through the SAME tokenizer that produced `ents`: a substring test credited
        # ga-abc for a mention of ga-abcdef (or ga-x for its child ga-x.4)
        mentioned = set(extract_entities((msg.get("subject") or "") + "\n" + (msg.get("body") or "")))
        # `ents`, not `live`: positive evidence still counts when the id it cites is gone — under doubt this
        # module leans to "agiu" (a missed action understates the grave-error count), never the reverse
        hit = [x for x in ents if x in mentioned]
        if hit:
            return "agiu", f"mail enviado pelo destinatario citando {hit[0]}"

    stray = []  # comments in the window that cannot be attributed to the recipient: (entity, author, why)
    for ent in live:
        for c in comments.get(ent) or []:
            if not isinstance(c, dict):
                stray.append((ent, "?", "comentario ilegivel"))
                continue
            author = c.get("author") or "?"
            ct = parse_ts(c.get("created_at"))
            if ct is None:  # cannot be placed in or out of the window: not "outside"
                stray.append((ent, author, "comentario sem data legivel"))
                continue
            if not t0 <= ct <= t1:
                continue
            if _actor_key(c.get("author")) in aliases:
                return "agiu", f"comentario do destinatario em {ent}"
            stray.append((ent, author, "comentario na janela"))

    if not ents:
        return "nao_sei", "entidade nao identificavel (sem bead citado)"
    if not live:
        return "nao_sei", (f"todos os beads citados ({', '.join(gone)}) nao existem mais no bd (bd: no issue found) — "
                           "sem entidade viva nao ha o que observar")
    unreadable = [x for x in live if comments.get(x) is None]
    if unreadable:
        return "nao_sei", (f"comentarios ilegiveis/indisponiveis em {unreadable[0]} (bd falhou, wisp ou rig desconhecido) "
                           "— ausencia de evidencia nao e nao-acao")
    changed = [x for x in live if any(str(e.get("type", "")).startswith("bead.") and e.get("subject") == x for e in window_events)]
    if changed:
        return "nao_sei", f"{changed[0]} mudou na janela mas o evento nao diz quem (bead.* vem como cache-reconcile) — sem autor atribuivel"
    if stray:
        ent, author, why = stray[0]
        return "nao_sei", (f"{ent} teve {why} de '{author}' e esse autor nao e atribuivel ao destinatario "
                           "(bd grava 'Test'/'automation'/outra grafia do mesmo agente) — sem autor atribuivel")
    if not events_complete:
        return "nao_sei", ("eventos ilegiveis na janela (arquivo truncado/corrompido): nao da pra afirmar que "
                           "a entidade nao mudou — ausencia de evidencia nao e nao-acao")
    return "nao_agiu", "nenhuma acao vista na entidade citada: sem comentario/mail do destinatario e nada mudou nela na janela"


# ── state, lock ────────────────────────────────────────────────────────────────────────────
def _new_state() -> dict:
    return {"cursor_seq": None, "nudges_seen": {}, "pending": {}, "resolved_ids": {}, "dup_ledger": {}}


def _load_state(cfg: Config):
    """(state, note). Missing file = first run (legitimately empty). An EXISTING file that cannot be
    parsed is not "empty": starting over would silently lose the cursor and every pending outcome, so
    the bad file is set aside (evidence) and the run line says so."""
    try:
        raw = cfg.state_file.read_text(encoding="utf-8")
    except FileNotFoundError:
        return _new_state(), None
    except OSError as e:
        return _new_state(), f"state_unreadable: {type(e).__name__}"
    try:
        s = json.loads(raw)
        if not isinstance(s, dict):
            raise ValueError("not an object")
    except (json.JSONDecodeError, ValueError):
        aside = cfg.state_file.with_name(cfg.state_file.name + f".corrupt-{int(time.time())}")
        try:
            os.replace(cfg.state_file, aside)
        except OSError:
            pass
        return _new_state(), f"state_corrupt: set aside as {aside.name}, restarted from activation"
    base = _new_state()
    base.update({k: v for k, v in s.items() if k in base})
    return base, None


def _save_state(cfg: Config, st: dict) -> None:
    _atomic_write(cfg.state_file, json.dumps(st, ensure_ascii=False))


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def acquire_lock(lock: Path) -> bool:
    lock.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            os.mkdir(lock)
            (lock / "pid").write_text(str(os.getpid()))
            return True
        except FileExistsError:
            try:
                pid = int((lock / "pid").read_text().strip())
                held = _pid_alive(pid)
            except (OSError, ValueError):
                # dir exists but no readable pid: another instance may be between mkdir and write
                try:
                    held = time.time() - lock.stat().st_mtime < 30
                except OSError:
                    held = False
            if held:
                return False
            for f in lock.glob("*"):
                try:
                    f.unlink()
                except OSError:
                    pass
            try:
                lock.rmdir()
            except OSError:
                return False
    return False


def release_lock(lock: Path) -> None:
    try:
        for f in lock.glob("*"):
            f.unlink()
        lock.rmdir()
    except OSError:
        pass


def _logged_ids(jev_log: Path):
    """delivery_ids already in the log's tail — the guard against a crash between the log append
    and the state save re-appending the same record. None = the log exists but could not be read:
    that is "cannot verify", NOT "nothing logged" (the caller then resolves nothing this run)."""
    ids: set = set()
    try:
        size = jev_log.stat().st_size
        with jev_log.open("rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            raw = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ids
    except OSError:
        return None
    for line in raw.splitlines():
        if '"portaria"' not in line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("mode") == "portaria" and r.get("delivery_id"):
            ids.add(r["delivery_id"])
    return ids


# ── the run ────────────────────────────────────────────────────────────────────────────────
def run_once(cfg: Config, jev_fn=None, bd_fn=None, now=None) -> dict:
    now = now or datetime.now(UTC)
    if jev_fn is None:
        jev_fn = jev.call_jev_multi
    if bd_fn is None:
        bd_fn = lambda rig, args: default_bd_runner(rig, args, cfg.bd_timeout_s)  # noqa: E731
    lock = cfg.state_file.parent / "portaria-shadow.lock"
    if not acquire_lock(lock):
        return {"skipped": "locked"}
    try:
        return _run_locked(cfg, jev_fn, bd_fn, now)
    finally:
        release_lock(lock)


def _run_locked(cfg: Config, jev_fn, bd_fn, now: datetime) -> dict:
    st, state_note = _load_state(cfg)
    stats: dict = {}
    run = {"jev_calls": 0, "jev_fail_streak": 0}
    bd = BdReader(cfg, bd_fn)
    summary = {"new": 0, "mail_new": 0, "nudge_new": 0, "resolved": 0, "unparseable": 0}
    if state_note:
        summary["state_warning"] = state_note

    nudge_state = _read_json(cfg.nudge_state, None)
    nudge_pending = nudge_state.get("pending") if isinstance(nudge_state, dict) else None
    nudge_dead = nudge_state.get("dead") if isinstance(nudge_state, dict) else None
    if not isinstance(nudge_pending, list):
        nudge_pending = None
    if not isinstance(nudge_dead, list):
        nudge_dead = None

    # ── activation ──
    if st["cursor_seq"] is None:
        # An unreadable/empty events file (rotation swapping it, disk trouble) must NOT become cursor 0:
        # the next run would read every archive and treat 40 hours of history as fresh deliveries,
        # with today's bead state as its "live facts". Activate only when the file says where it is.
        anchor = _last_event(cfg.events_file) if cfg.bootstrap == "tail" else _first_event(cfg.events_file)
        if anchor is None or not isinstance(anchor.get("seq"), int):
            return {"skipped": "events_unreadable_at_activation", **summary}
        if cfg.bootstrap == "tail":
            st["cursor_seq"] = anchor["seq"]
            for it in nudge_pending or []:
                if isinstance(it, dict) and it.get("id"):
                    st["nudges_seen"][it["id"]] = ts_z(now)
        else:
            st["cursor_seq"] = anchor["seq"] - 1
        _save_state(cfg, st)

    # A hole between the cursor and what the files still hold (an archive pruned before we read it) is
    # lost deliveries — say so in the run line instead of pretending the observation is complete.
    gap = _events_gap(cfg.events_file, st["cursor_seq"])
    if gap:
        summary["gap_events"] = gap

    def add_pending(d: dict) -> None:
        facts = None
        if not d["protegida"]:
            ent0 = next((x for x in d["entidades"] if rig_for_entity(x, cfg.rig_paths)), None)
            facts = bd.facts(ent0) if ent0 else None
        c1, regra = layer1(d, st["dup_ledger"], facts, cfg)
        d["fatos"] = bool(facts)
        d["camada1"], d["camada1_regra"] = c1, regra
        d.update(layer2(d, facts, cfg, jev_fn, run))
        d["cascata"] = "pular" if (d["camada1"] == "pular" or d["camada2"] == "pular") else "seguir"
        d["camada3"] = "nao_alcancada" if d["cascata"] == "pular" else "acordaria"
        d.pop("text", None)
        st["pending"][d["delivery_id"]] = d
        summary["new"] += 1

    # ── observe: new mail deliveries (cursor by seq; saved after every delivery) ──
    last_seq = st["cursor_seq"]
    exhausted = False
    for ev in iter_events(cfg.events_file, since_seq=st["cursor_seq"], stats=stats):
        seq = ev.get("seq")
        if ev.get("type") == "mail.sent":
            d = mail_delivery(ev)
            if d is None:
                stats["unparseable"] = stats.get("unparseable", 0) + 1
            elif d["delivery_id"] not in st["pending"] and d["delivery_id"] not in st["resolved_ids"]:
                if summary["mail_new"] >= cfg.max_per_run:
                    exhausted = True  # this mail is NOT consumed: the cursor stays before it
                    break
                add_pending(d)
                summary["mail_new"] += 1
                if isinstance(seq, int):
                    last_seq = max(last_seq, seq)
                st["cursor_seq"] = last_seq
                _save_state(cfg, st)
                continue
        if isinstance(seq, int):
            last_seq = max(last_seq, seq)
    st["cursor_seq"] = last_seq

    # ── observe: new nudges (by id; the queue is a snapshot, nudges never become events) ──
    if nudge_pending is not None and not exhausted:
        fresh = [it for it in nudge_pending if isinstance(it, dict) and it.get("id") and it["id"] not in st["nudges_seen"]]
        fresh.sort(key=lambda it: it.get("created_at") or "")
        for it in fresh:
            if summary["mail_new"] + summary["nudge_new"] >= cfg.max_per_run:
                break
            st["nudges_seen"][it["id"]] = ts_z(now)
            d = nudge_delivery(it)
            if d is None:
                stats["unparseable"] = stats.get("unparseable", 0) + 1
                continue
            add_pending(d)
            summary["nudge_new"] += 1
    st["nudges_seen"] = {k: v for k, v in st["nudges_seen"].items() if (parse_ts(v) or now) >= now - timedelta(days=3)}
    st["dup_ledger"] = {k: v for k, v in st["dup_ledger"].items() if (parse_ts(v) or now) >= now - timedelta(hours=24)}
    _save_state(cfg, st)

    # ── resolve: window closed AND fully covered by events already written ──
    janela = timedelta(minutes=cfg.janela_min)
    grace = timedelta(seconds=cfg.grace_s)
    last_ev = _last_event(cfg.events_file)
    latest_ts = parse_ts(last_ev.get("ts")) if last_ev else None
    due = []
    for did, rec in st["pending"].items():
        t0 = parse_ts(rec["ts"])
        if t0 is not None and now >= t0 + janela + grace and latest_ts is not None and latest_ts >= t0 + janela:
            due.append((t0, did, rec))
    if due:
        due.sort(key=lambda t: t[0])
        already = _logged_ids(cfg.jev_log)
        if already is None:
            summary["log_warning"] = "experiment log unreadable: resolution skipped this run (cannot rule out duplicates)"
            due = []
    if due:
        lo = due[0][0]
        hi = max(t0 for t0, _, _ in due) + janela
        wevents = []
        unreadable_before = stats.get("unreadable_files", 0)
        for e in iter_events(cfg.events_file, since_ts=lo, stats=stats):
            et = parse_ts(e.get("ts"))
            if et is not None and lo <= et <= hi and (e.get("type") == "mail.sent" or str(e.get("type", "")).startswith("bead.")):
                wevents.append((et, e))
        # a file that could not be read to its end means events of the window may be MISSING here —
        # that is "cannot tell", never "nothing happened" (gate ga-aijm2v.4 #2: the count was kept
        # and never read, so a truncated archive resolved every delivery it hid as nao_agiu)
        window_unreadable = stats.get("unreadable_files", 0) - unreadable_before
        retry = timedelta(minutes=cfg.unreadable_retry_min)
        ids_pending = {it.get("id") for it in nudge_pending or [] if isinstance(it, dict)}
        ids_dead = {it.get("id") for it in nudge_dead or [] if isinstance(it, dict)}
        for t0, did, rec in due:
            if did in already:  # logged before a crash lost the state save: never append twice
                del st["pending"][did]
                st["resolved_ids"][did] = ts_z(now)
                _save_state(cfg, st)
                continue
            t1 = t0 + janela
            if window_unreadable and now < t1 + retry:
                # the next run usually reads it whole (rotation race, transient I/O): keep it pending,
                # and past the retry limit fall through to compute_outcome(events_complete=False)
                summary["deferred_unreadable"] = summary.get("deferred_unreadable", 0) + 1
                continue
            comments = {ent: bd.comments(ent) for ent in rec["entidades"]}
            if any(v is DEFERRED for v in comments.values()):
                continue  # bd budget/breaker this run: try again next run, conclude nothing
            in_window = [e for et, e in wevents if t0 <= et <= t1]
            desfecho, motivo = compute_outcome(rec, t0, t1, in_window, comments, events_complete=not window_unreadable)
            out = {
                "ts": rec["ts"], "mode": "portaria", "experiment": f"portaria-{rec['classe']}", "classe": rec["classe"],
                "canal": rec["canal"], "delivery_id": did, "destinatario": rec["destinatario"], "entidades": rec["entidades"],
                "entidades_inexistentes": gone_entities(rec["entidades"], comments), "fatos": rec.get("fatos"), "camada1": rec["camada1"], "camada1_regra": rec["camada1_regra"], "camada2": rec["camada2"],
                "camada2_noul": rec["camada2_noul"], "camada2_extras": rec["camada2_extras"], "camada3": rec["camada3"],
                "cascata": rec["cascata"], "jev_ok": rec["jev_ok"], "jev_noul": rec["jev_noul"], "jev_error": rec["jev_error"],
                "jev_tokens_in": rec["jev_tokens_in"], "jev_tokens_out": rec["jev_tokens_out"],
                "desfecho": desfecho, "desfecho_motivo": motivo, "janela_min": cfg.janela_min, "resolved_at": ts_z(now),
            }
            if rec["canal"] == "nudge":
                nid = did.split(":", 1)[1]
                out["nudge_estado"] = ("desconhecido" if nudge_pending is None else
                                       "pendente" if nid in ids_pending else "morta" if nid in ids_dead else "entregue")
            _append_jsonl(cfg.jev_log, out)
            del st["pending"][did]
            st["resolved_ids"][did] = ts_z(now)
            _save_state(cfg, st)
            summary["resolved"] += 1
    st["resolved_ids"] = {k: v for k, v in st["resolved_ids"].items() if (parse_ts(v) or now) >= now - timedelta(days=3)}
    _save_state(cfg, st)

    summary["unparseable"] = stats.get("unparseable", 0)
    if stats.get("unreadable_files"):
        # events lost to a truncated/corrupt/vanished file: on the run line so it is never silent
        # (a mail in a cut archive is a delivery this run never saw — the cursor moves on regardless)
        summary["unreadable_files"] = stats["unreadable_files"]
    summary["pending"] = len(st["pending"])
    summary["jev_calls"] = run["jev_calls"]
    summary["bd_calls"] = bd.calls
    # a rig map that came back with only the HQ means every non-ga entity's outcome is nao_sei —
    # say so in the run line instead of letting it look like "nothing to measure"
    summary["rig_prefixes"] = sorted(cfg.rig_paths)
    if len(cfg.rig_paths) < 2:
        summary["warning"] = "rig map has only the HQ prefix: every non-ga entity's outcome is nao_sei"
    return summary


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else "run"
    cfg = config_from_env()
    if cmd == "status":
        st, _note = _load_state(cfg)
        print(json.dumps({"cursor_seq": st["cursor_seq"], "pending": len(st["pending"]), "resolved_ids": len(st["resolved_ids"]),
                          "nudges_seen": len(st["nudges_seen"]), "state_file": str(cfg.state_file)}))
        return 0
    if cmd != "run":
        print(f"usage: portaria_shadow.py [run|status]", file=sys.stderr)
        return 2
    if os.environ.get("PORTARIA_ENABLED", "1") != "1":
        print("portaria-shadow: disabled via PORTARIA_ENABLED -- skipping")
        return 0
    if (cfg.state_file.parent / "portaria-shadow.disabled").exists():
        print("portaria-shadow: disabled via portaria-shadow.disabled -- skipping")
        return 0
    t = time.time()
    s = run_once(cfg)
    s["seconds"] = round(time.time() - t, 1)
    print("portaria-shadow: " + json.dumps(s, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
