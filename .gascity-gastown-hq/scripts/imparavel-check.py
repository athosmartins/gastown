#!/usr/bin/env python3
"""
imparavel-check — O teste FALSIFICÁVEL de "está imparável?".

Athos não roda código. Quando ele pergunta "está imparável?", o Mayor roda ISTO
e traz o veredito honesto. Este script NÃO dá opinião — mede a definição:

  IMPARÁVEL (def. A — a única atingível) =
    (1) NENHUMA bead GENUINAMENTE CONSTRUÍVEL da fila do Pilot está parada em silêncio.
        "Fila do Pilot" = pilot-dispatchable.json (~/.gc/pilot-dispatchable.json).
        "Genuinamente construível" = na fila do Pilot SEM label de bloqueio
        (gate:needs-human, story:needs-human, on-device, story:needs-device, blocked,
        story:blocked — esses são PARKED, não falha silenciosa) E que NÃO esteja
        JÁ CONSTRUÍDA / no pipeline do gate (bead com quality-gate-marker aberto
        apontando pra ela, ou label gate:* de ciclo-de-vida) — essa é responsabilidade
        do GATE (check 2), não uma falha silenciosa de dispatch do Pilot.
        Uma construível sem story:in-flight, sem hold legítimo, com pilot vivo = FALHA
        — EXCEÇÃO (ga-wmrr): se o POOL está saturado (0 slots livres em TODAS as
        lanes small/big, lido do log do Pilot), a fila normal atrás de capacidade
        cheia NÃO é FALHA (só falta vaga, não houve skip de dispatch).
    (2) O gate não está travado em silêncio
        (se há marker queued/dispatching, tem que haver progresso: um merge
         recente OU um reviewer vivo. needs-rebase/error = PARKED, não é stall.)
    (3) O pilot (dispatcher) está vivo.
    (4) O Dolt responde.

  Princípio: na dúvida, FLAGA (nunca um ✅ falso). Melhor apontar um não-problema
  que esconder um stall real. Saída: relatório em PT + 'VEREDITO: ...' + exit 0/1/2.

  NOTA CRÍTICA: labels são lidos via `bd show` (plain text), NUNCA com --json.
  `bd show --json` retorna vazio/quebrado neste ambiente — uso plain text + grep LABELS:.
"""
import json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import park_labels

# ga-26us5: reuse the SAME delivery-stall threshold throughput-stall-watchdog.py (imp23)
# uses for DELIVERY_STALL_HOURS, so this check's "building now" count and the watchdog's
# delivery-stall alarm can never drift apart and disagree again — the recurring
# error-and-empty-must-not-produce-the-same-value class, applied to this file itself.
# The watchdog's filename has a hyphen so it isn't a valid module name for a plain
# `import` — load by path, the same technique test_production_stall_watchdog.py already
# uses for its hyphenated sibling. Any load failure falls back to the watchdog's own
# documented default (3h) and is surfaced as a warning — never a silent guess.
import importlib.util as _importlib_util
_TSW_LOAD_WARN = None
try:
    _tsw_spec = _importlib_util.spec_from_file_location(
        "throughput_stall_watchdog",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "throughput-stall-watchdog.py"))
    _tsw = _importlib_util.module_from_spec(_tsw_spec)
    _tsw_spec.loader.exec_module(_tsw)
    DELIVERY_STALL_HOURS = _tsw.DELIVERY_STALL_HOURS
except Exception as _tsw_exc:
    DELIVERY_STALL_HOURS = float(os.environ.get("TSW_DELIVERY_STALL_HOURS", "3"))
    _TSW_LOAD_WARN = ("não consegui importar DELIVERY_STALL_HOURS de throughput-stall-watchdog.py"
                       " (%s) — usando default %.0fh, pode divergir" % (str(_tsw_exc)[:80], DELIVERY_STALL_HOURS))

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
RIGS = [("HQ", CITY),
        ("WA", "/Users/athos/gt/whatsapp_automation"),
        ("PS", "/Users/athos/gt/property_scrapers")]
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
BD = os.environ.get("BD_BIN", "bd")
GC = os.environ.get("GC_BIN", "gc")
DISPATCHABLE_JSON = os.path.expanduser("~/.gc/pilot-dispatchable.json")

STARVE_MIN = int(os.environ.get("IMP_STARVE_MIN", "20"))
HELD_LOOP_MAX = int(os.environ.get("IMP_HELD_LOOP_MAX", "5"))
GATE_STALL_MIN = int(os.environ.get("IMP_GATE_STALL_MIN", "165"))
PILOT_DEAD_MIN = int(os.environ.get("IMP_PILOT_DEAD_MIN", "20"))
MAX_CLASSIFY = int(os.environ.get("IMP_MAX_CLASSIFY", "40"))  # cap to avoid hanging

# Labels that mark a bead as NOT auto-dispatchable right now (not a silent stall).
# A bead carrying ANY of these is parked for a real reason — the Pilot correctly
# won't auto-dispatch it, so it is NOT a "buildable bead silently stuck".
#
# ga-hzt8s: sourced from the canonical park_labels.py vocabulary (shared with
# approved-state-reconciler.py + throughput-stall-watchdog.py) so this list
# can't drift out of sync with the other two the way it did before. "status"
# is imparavel-specific (a synthetic label _bd_show_labels_text() derives from
# the bead's STATUS header, not a real bead label) and stays local.
PARKING_LABELS = tuple(park_labels.PARK_LABELS) + ("status",)

NOW = time.time()


def _sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _bd_json(root, label, status="open"):
    """Returns (list_or_None, ok). ok=False on read error (→ flag, never false-pass)."""
    r = _sh([BD, "-C", root, "list", "-l", label, "--status", status, "--json", "-n", "200"])
    if r is None or r.returncode != 0:
        return None, False
    try:
        d = json.loads(r.stdout or "[]")
        return (d if isinstance(d, list) else d.get("issues", d.get("beads", []))), True
    except Exception:
        return None, False


def _age_min(iso):
    """Minutes since an ISO timestamp; None if unparseable (→ caller treats conservatively)."""
    if not iso:
        return None
    s = str(iso).strip().replace("Z", "+00:00")
    try:
        import datetime
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return max(0.0, (NOW - dt.timestamp()) / 60.0)
    except Exception:
        return None


def _labels(b):
    l = b.get("labels", []) or []
    return l if isinstance(l, list) else []


def _root_for_bead(bead_id, store=None):
    """Return (root_path, rig_name) for a bead, by store field or id prefix."""
    if store == "whatsapp_automation":
        return "/Users/athos/gt/whatsapp_automation", "WA"
    if store == "property_scrapers":
        return "/Users/athos/gt/property_scrapers", "PS"
    if store == "hq":
        return CITY, "HQ"
    # Fallback by id prefix
    if bead_id.startswith("wa-"):
        return "/Users/athos/gt/whatsapp_automation", "WA"
    if bead_id.startswith("ps-"):
        return "/Users/athos/gt/property_scrapers", "PS"
    return CITY, "HQ"


def _bd_show_labels_text(root, bead_id):
    """Get labels list from `bd show` plain-text output. NEVER uses --json (broken).
    Returns list of label strings, [] if none, or None on read error.
    ALSO synthesizes a 'status:deferred'/'status:blocked' parking label from the bead's
    STATUS — the Pilot won't dispatch a DEFERRED/BLOCKED bead, and status is NOT a label
    (it lives in the header line '... [● P2 · DEFERRED]'), so the check must read it too."""
    r = _sh([BD, "-C", root, "show", bead_id], timeout=15)
    if r is None or r.returncode != 0:
        return None
    labels = []
    upper = r.stdout.upper()
    if "· DEFERRED]" in upper or " DEFERRED]" in upper:
        labels.append("status:deferred")
    if "· BLOCKED]" in upper or " BLOCKED]" in upper:
        labels.append("status:blocked")
    for line in r.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("LABELS:"):
            raw = stripped.split("LABELS:", 1)[1].strip()
            labels.extend(l.strip() for l in raw.split(",") if l.strip())
            break
    return labels


def _label_matches(label, base):
    """A label matches a base if it is the base exactly, or a colon-suffixed
    (gate:needs-human:on-device) or dash-suffixed (needs:rehome-property) variant.
    Delegates to the canonical matcher (ga-hzt8s) — kept as a local name since
    every call site in this file already uses it."""
    return park_labels.label_matches(label, base)


def _label_is_parking(label):
    """Returns True if this label means the bead is not auto-dispatchable right now."""
    return any(_label_matches(label, park) for park in PARKING_LABELS)


def _label_is_gate_inflight(label):
    """Returns True if this label means the bead is ALREADY BUILT and in the
    quality-gate pipeline (reviewing / needs-rebase / error / passed / merging /
    queued / dispatching / fix-attempt / …) — i.e. downstream of the Pilot's dispatch,
    NOT a silent buildable stall. That is the GATE's domain (check_gate), so the
    buildable-queue verdict must not double-count it as a Pilot dispatch failure.

    EXCEPTION — gate:needs-fix: the gate bounced the bead back for a code fix, so it
    is a fresh dispatch candidate again (mirrors the Pilot's _filter_built carve-out).
    The caller gates the label path on `bounced` so gate:needs-fix stays eligible to
    be flagged when there is NO active gate run (no open marker) holding it.
    gate:needs-human is handled by PARKING_LABELS above; excluded here defensively."""
    if not (label == "gate" or label.startswith("gate:")):
        return False
    if _label_matches(label, "gate:needs-fix") or _label_matches(label, "gate:needs-human"):
        return False
    return True


def _gate_source_beads():
    """Set of bead ids that have an OPEN quality-gate-marker (label source-bead:<id>).
    Such a bead is already built and in the gate pipeline — the gate owns it now
    (whether the gate is progressing is check_gate's job), so it is NOT a silent
    Pilot-dispatch stall. Read once per run; returns an EMPTY set on any read error
    so a Dolt hiccup never SUPPRESSES a real stall (fail-open toward flagging)."""
    ids = set()
    markers, ok = _bd_json(CITY, "type:quality-gate-marker")
    if not ok or not markers:
        return ids
    for m in markers:
        for l in _labels(m):
            s = str(l)
            if s.startswith("source-bead:"):
                bid = s.split("source-bead:", 1)[1].strip()
                if bid:
                    ids.add(bid)
    return ids


def classify_bead(bead_id, labels, gate_source_beads, held_loop_max=HELD_LOOP_MAX):
    """PURE classifier (no I/O — unit-testable). Given a bead's LIVE labels + the set
    of in-gate source-bead ids, return (kind, reason) where kind is one of:
      'parked'  — not a silent stall (parking label, OR already-built/in-gate).
      'flowing' — story:in-flight (building now).
      'held'    — pilot:held-until:* within the loop budget (legit temporary defer).
      'stuck'   — genuinely buildable, not flowing/held → a silent stall (reason set
                  to 'held-loop:Nx' when a held bead exceeded the re-hold budget).
    Precedence: parking-label > active-gate-marker > in-gate-label(non-needs-fix) >
    in-flight > held > stuck."""
    if any(_label_is_parking(l) for l in labels):
        return ("parked", "label")
    # An ACTIVE gate marker names it → the gate owns it (gate-stall = check_gate's job),
    # regardless of gate:needs-fix (a re-queued fix-attempt is still in the gate now).
    if bead_id in gate_source_beads:
        return ("parked", "in-gate")
    # No active marker: a gate:* lifecycle label still means already-built/in-gate,
    # UNLESS the gate bounced it back for a fix (needs-fix ⇒ re-dispatchable candidate).
    bounced = any(_label_matches(l, "gate:needs-fix") for l in labels)
    if not bounced and any(_label_is_gate_inflight(l) for l in labels):
        return ("parked", "in-gate")
    if "story:in-flight" in labels:
        return ("flowing", "")
    held = [l for l in labels if l.startswith("pilot:held-until:")]
    if held:
        if len(held) > held_loop_max:
            return ("stuck", "held-loop:%dx" % len(held))
        return ("held", "")
    return ("stuck", "")


def classify_in_flight(age_min, stall_min):
    """PURE classifier (no I/O — unit-testable). A story:in-flight bead only counts
    as 'building' while it shows real recent progress: age_min (minutes since
    updated_at, None if unparseable) within stall_min of now. Beyond that window —
    or when age can't be determined at all — it is 'delivery-stalled': the same
    threshold throughput-stall-watchdog's DELIVERY_STALL_HOURS (imp23) uses, so the
    two checks can't drift apart and disagree (ga-26us5). Unknown age is treated as
    stalled, not building — an unverifiable timestamp must never stand in for
    confirmed progress (same class this whole file exists to catch)."""
    if age_min is not None and age_min <= stall_min:
        return "building"
    return "delivery-stalled"


# ── CHECK 1: pilot dispatchable queue ────────────────────────────────────────
def check_approved():
    """
    Primary path: reads pilot-dispatchable.json and classifies each bead by real labels
    via `bd show` (plain text). Falls back to story:approved if snapshot is missing/stale.

    Returns dict with keys:
      total, parked_count, buildable_count, flowing_count, held_count,
      stuck (list of {id, rig, title}), read_err (list of bead ids),
      warns (list of warning strings), from_dispatchable (bool), snap_age_min,
      _ok_reasons (fallback only), _total_approved (fallback only)
    """
    warns = []

    # --- load pilot-dispatchable.json ---
    items = None
    snap_age_min = None
    try:
        with open(DISPATCHABLE_JSON) as f:
            snap = json.load(f)
        gen_at = snap.get("generated_at", "")
        ttl = int(snap.get("ttl_seconds", 600))
        snap_age_min = _age_min(gen_at)
        ttl_min = ttl * 2 / 60.0
        if snap_age_min is None or snap_age_min > ttl_min:
            warns.append(
                "snapshot dispatchable desatualizado (%.0fmin > ttl×2=%.0fmin) — usando story:approved como fallback"
                % (snap_age_min if snap_age_min is not None else 9999, ttl_min))
        else:
            items = snap.get("items", [])
    except FileNotFoundError:
        warns.append("~/.gc/pilot-dispatchable.json ausente — usando story:approved como fallback")
    except Exception as exc:
        warns.append("erro ao ler pilot-dispatchable.json (%s) — usando story:approved" % str(exc)[:80])

    if items is None:
        return _check_approved_fallback(warns)

    # --- classify each dispatchable bead (cap at MAX_CLASSIFY) ---
    # Read the in-gate set ONCE (beads with an open quality-gate-marker): an
    # already-built bead awaiting the gate must NEVER count as a silent Pilot stall.
    gate_source_beads = _gate_source_beads()
    parked, buildable, stuck = [], [], []
    flowing_count, held_count, in_gate_count = 0, 0, 0
    read_err = []

    for item in items[:MAX_CLASSIFY]:
        bead_id = item.get("id", "")
        store = item.get("store", "")
        title = (item.get("title") or "")[:55]
        root, rig = _root_for_bead(bead_id, store)

        labels = _bd_show_labels_text(root, bead_id)
        if labels is None:
            read_err.append(bead_id)
            continue

        kind, reason = classify_bead(bead_id, labels, gate_source_beads)

        # PARKED: parking label OR already-built/in-gate → not a silent stall.
        if kind == "parked":
            parked.append({"id": bead_id, "title": title, "rig": rig, "reason": reason})
            if reason == "in-gate":
                in_gate_count += 1
            continue

        # GENUINELY BUILDABLE (everything not parked: flowing / held / stuck)
        buildable.append({"id": bead_id, "title": title, "rig": rig,
                          "flowing": kind == "flowing", "held": kind == "held"})
        if kind == "flowing":
            flowing_count += 1
        elif kind == "held":
            held_count += 1
        else:  # 'stuck' (plain, or held-loop — reason carries "held-loop:Nx")
            s = {"id": bead_id, "rig": rig, "title": title}
            if reason:
                s["reason"] = reason
            stuck.append(s)

    return {
        "total": len(items),
        "parked_count": len(parked),
        "in_gate_count": in_gate_count,
        "buildable_count": len(buildable),
        "flowing_count": flowing_count,
        "held_count": held_count,
        "stuck": stuck,
        "read_err": read_err,
        "warns": warns,
        "from_dispatchable": True,
        "snap_age_min": snap_age_min,
    }


def _check_approved_fallback(inherited_warns):
    """Fallback: story:approved-only logic when pilot-dispatchable.json is unavailable."""
    stuck, total = [], 0
    ok_in_flight, ok_held, ok_mayor, ok_fresh, ok_in_gate = 0, 0, 0, 0, 0
    warns = list(inherited_warns)
    gate_source_beads = _gate_source_beads()

    for name, root in RIGS:
        beads, ok = _bd_json(root, "story:approved")
        if not ok:
            warns.append("não consegui ler story:approved de: %s (Dolt/bd)" % name)
            continue
        for b in beads:
            total += 1
            labs = _labels(b)
            ls = " ".join(labs)
            asg = (b.get("assignee") or "")
            if "story:in-flight" in labs:
                ok_in_flight += 1; continue
            if any(l.startswith("pilot:held-until") for l in labs):
                ok_held += 1; continue
            if asg == "mayor":
                ok_mayor += 1; continue
            if any(r in ls for r in ("story:needs-device", "story:needs-human", "story:blocked")):
                continue
            # already-built / in the gate pipeline → the gate owns it, not a silent
            # Pilot stall (open marker is authoritative; gate:* label unless needs-fix).
            if b.get("id") in gate_source_beads:
                ok_in_gate += 1; continue
            if (not any(_label_matches(l, "gate:needs-fix") for l in labs)
                    and any(_label_is_gate_inflight(l) for l in labs)):
                ok_in_gate += 1; continue
            held = [l for l in labs if l.startswith("pilot:held-until:")]
            if held:
                if len(held) > HELD_LOOP_MAX:
                    stuck.append({"rig": name, "id": b.get("id"),
                                  "title": (b.get("title", "") or "")[:55],
                                  "reason": "held-loop:%dx" % len(held)})
                    continue
                future = False
                for l in held:
                    try:
                        if float(l.rsplit(":", 1)[1]) > NOW:
                            future = True; break
                    except Exception:
                        pass
                if future:
                    ok_held += 1; continue
            age = _age_min(b.get("updated_at"))
            if age is not None and age <= STARVE_MIN:
                ok_fresh += 1; continue
            stuck.append({"rig": name, "id": b.get("id"),
                          "title": (b.get("title", "") or "")[:55],
                          "reason": ("%dmin" % round(age)) if age is not None else "idade?"})

    return {
        "total": total,
        "parked_count": ok_held + ok_mayor + ok_in_gate,
        "in_gate_count": ok_in_gate,
        "buildable_count": total - len(stuck) - ok_in_flight,
        "flowing_count": ok_in_flight,
        "held_count": ok_held,
        "stuck": stuck,
        "read_err": [],  # already surfaced in warns
        "warns": warns,
        "from_dispatchable": False,
        "snap_age_min": None,
        "_ok_reasons": {"in-flight": ok_in_flight, "held": ok_held,
                        "mayor": ok_mayor, "fresh": ok_fresh, "in-gate": ok_in_gate},
        "_total_approved": total,
    }


# ── CHECK 2: gate silently stalled ───────────────────────────────────────────
def check_gate():
    markers, ok = _bd_json(CITY, "type:quality-gate-marker")
    if not ok:
        return {"read_err": True}
    active, parked, oldest_active_min = [], [], None
    for m in markers:
        ls = " ".join(_labels(m))
        if "gate-status:queued" in ls or "gate-status:dispatching" in ls:
            active.append(m.get("id"))
            age = _age_min(m.get("updated_at"))
            if age is not None and (oldest_active_min is None or age > oldest_active_min):
                oldest_active_min = age
        elif "gate-status:needs-rebase" in ls or "gate-status:error" in ls:
            parked.append(m.get("id"))
    # last Gate PASSED
    last_pass_min = None
    r = _sh(["tail", "-n", "4000", DISPATCH_LOG])
    if r and r.stdout:
        import re
        for line in reversed(r.stdout.splitlines()):
            if "Gate PASSED:" in line:
                mt = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]", line)
                if mt:
                    try:
                        import datetime
                        dt = datetime.datetime.strptime(mt.group(1), "%Y-%m-%d %H:%M:%S")
                        last_pass_min = max(0.0, (NOW - dt.timestamp()) / 60.0)
                    except Exception:
                        pass
                break
    # live gate-reviewer?
    rv = _sh([GC, "session", "list"])
    reviewer_alive = bool(rv and rv.stdout and
                          any("gate-reviewer" in ln and ("active" in ln or "awake" in ln)
                              for ln in rv.stdout.splitlines()))
    stalled_by_age = (oldest_active_min is not None and oldest_active_min > GATE_STALL_MIN)
    stalled_by_silence = (len(active) > 0
                          and (last_pass_min is None or last_pass_min > GATE_STALL_MIN)
                          and not reviewer_alive)
    return {"active": active, "parked": parked, "last_pass_min": last_pass_min,
            "reviewer_alive": reviewer_alive, "oldest_active_min": oldest_active_min,
            "stalled": stalled_by_age or stalled_by_silence,
            "stall_reason": ("marker preso há %dmin (reviewer pode estar congelado)" % oldest_active_min
                             if stalled_by_age else
                             "0 merge na janela + nenhum reviewer vivo" if stalled_by_silence else "")}


# ── CHECK 3 & 4: pilot + dolt liveness ───────────────────────────────────────
def _pilot_slots():
    """Most recent 'Available slots: small=X  big=Y' line from the Pilot log —
    the same line pilot-dispatcher.sh emits from MAX_lane - in_flight_lane.
    Returns {'small': int, 'big': int}, or None if the log is missing/unreadable
    or has no such line yet. Caller must treat None as 'unknown' and fall back
    to the pre-ga-wmrr strict behavior — an unreadable signal must never
    SUPPRESS a real stall; only a POSITIVELY-confirmed 0/0 may downgrade one."""
    r = _sh(["tail", "-n", "500", PILOT_LOG])
    if not (r and r.stdout):
        return None
    import re
    for line in reversed(r.stdout.splitlines()):
        mt = re.search(r"Available slots:\s*small=(\d+)\s+big=(\d+)", line)
        if mt:
            return {"small": int(mt.group(1)), "big": int(mt.group(2))}
    return None


def check_pilot():
    r = _sh(["tail", "-n", "60", PILOT_LOG])
    if not (r and r.stdout):
        return {"alive": None}
    import re, datetime
    last = None
    for line in reversed(r.stdout.splitlines()):
        mt = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]", line)
        if mt:
            try:
                dt = datetime.datetime.strptime(mt.group(1), "%Y-%m-%d %H:%M:%S")
                last = max(0.0, (NOW - dt.timestamp()) / 60.0)
            except Exception:
                pass
            break
    return {"alive": (last is not None and last < PILOT_DEAD_MIN), "last_sweep_min": last}


def check_dolt():
    t0 = time.time()
    r = _sh([BD, "-C", CITY, "list", "-n", "1", "--json"], timeout=15)
    ms = (time.time() - t0) * 1000
    return {"responsive": bool(r and r.returncode == 0), "latency_ms": round(ms)}


def main():
    a = check_approved()
    g = check_gate()
    p = check_pilot()
    d = check_dolt()
    slots = _pilot_slots()

    fails, warns, notes = [], [], []

    if _TSW_LOAD_WARN:
        warns.append(_TSW_LOAD_WARN)

    # --- Buildable queue verdict ---
    for w in a.get("warns", []):
        warns.append(w)
    if a["read_err"]:
        warns.append("não consegui classificar %d bead(s) (bd show falhou): %s"
                     % (len(a["read_err"]), ", ".join(str(x) for x in a["read_err"][:8])))

    # ga-wmrr: a construível queued behind a FULLY saturated pool (0 slots free
    # in EVERY lane) has nowhere to go regardless of its own lane — that is
    # healthy high-demand queueing (the reported HÍGIDO-e-CHEIO incident), not a
    # silent stall. Only report a real ❌ when some lane still has room and the
    # queue didn't use it (a genuine skip: empty routed_to, or a dispatch bug).
    pool_saturated = bool(slots) and slots["small"] <= 0 and slots["big"] <= 0

    if a["stuck"] and (p.get("alive") is not False):
        if pool_saturated:
            notes.append(
                "pool saturado (slots small=%d big=%d) — %d construível(is) normalmente"
                " na fila atrás de slots cheios, NÃO é falha: %s"
                % (slots["small"], slots["big"], len(a["stuck"]),
                   ", ".join("%s/%s" % (s["rig"], s["id"]) for s in a["stuck"][:6])))
        elif a.get("from_dispatchable"):
            fails.append(
                "%d bead(s) CONSTRUÍVEIS na fila do Pilot, 0 em build (pilot vivo): %s"
                % (len(a["stuck"]),
                   ", ".join("%s/%s" % (s["rig"], s["id"]) for s in a["stuck"][:6])))
        else:
            # fallback path
            fails.append(
                "%d bead(s) APROVADA(s) parada(s) em silêncio (pilot vivo, fallback story:approved): %s"
                % (len(a["stuck"]),
                   ", ".join("%s/%s (%s)" % (s["rig"], s["id"], s.get("reason", "?"))
                             for s in a["stuck"][:6])))

    # --- Gate check ---
    if g.get("read_err"):
        warns.append("não consegui ler os gate markers — investigar")
    elif g.get("stalled"):
        fails.append("GATE travado: %d marker(s) na fila — %s"
                     % (len(g["active"]), g.get("stall_reason", "sem progresso")))
    if p.get("alive") is False:
        fails.append("PILOT (dispatcher) MORTO: último sweep há %s min" % p.get("last_sweep_min"))
    if not d.get("responsive"):
        fails.append("DOLT não responde (bd query falhou) — coletar diagnóstico antes de reiniciar")

    # REAL building count across ALL stores (HQ+rigs). The dispatchable flowing_count is
    # ~0 by construction (dispatchable = not-yet-dispatched); rig-native builds (ps-/wa-)
    # carry story:in-flight in their OWN store, invisible to an HQ-only view (the same
    # cross-store class that bit the daemons). This is the honest "is the machine
    # producing RIGHT NOW?" signal — without it the check under-reports active builds.
    # ga-26us5: a story:in-flight label alone is not proof of progress — a worker can
    # reach a terminal state (device flaky, crashed, abandoned) and leave the label
    # stale. Cross-check against the delivery-stall threshold (same source as
    # throughput-stall-watchdog's DELIVERY_STALL_HOURS, imp23) and exclude anything
    # past it from "building now"; name it explicitly instead so it reads as
    # awaiting-human, not phantom progress.
    stall_min = DELIVERY_STALL_HOURS * 60
    building_ids, stalled_ids = [], []
    for _bn_name, _bn_root in RIGS:
        _bn_beads, _bn_ok = _bd_json(_bn_root, "story:in-flight")
        if not _bn_ok or not _bn_beads:
            continue
        for _bn_b in _bn_beads:
            _bn_id = _bn_b.get("id", "")
            if not _bn_id or "wisp" in _bn_id:
                continue
            _bn_age = _age_min(_bn_b.get("updated_at"))
            if classify_in_flight(_bn_age, stall_min) == "building":
                building_ids.append("%s/%s" % (_bn_name, _bn_id))
            else:
                stalled_ids.append("%s/%s" % (_bn_name, _bn_id))
    building_now = len(building_ids)

    # --- Report ---
    print("═══ CHECK IMPARÁVEL — %s ═══" % time.strftime("%Y-%m-%d %H:%M %Z"))
    print("")

    if a.get("from_dispatchable"):
        snap_note = ("snapshot %.0fmin atrás" % a["snap_age_min"]) if a.get("snap_age_min") is not None else ""
        print("FILA DO PILOT (dispatchable%s): %d total"
              % ((" — " + snap_note) if snap_note else "", a["total"]))
        if slots:
            print("  • slots do Pilot: small=%d livre(s)   big=%d livre(s)"
                  % (slots["small"], slots["big"]))
        print("  • parked (needs-human/on-device/blocked/já-no-gate): %d (já-construídas-no-gate: %d)"
              "   • genuinamente construíveis: %d   • em build agora (in-flight): %d   • held: %d"
              % (a["parked_count"], a.get("in_gate_count", 0),
                 a["buildable_count"], a["flowing_count"], a["held_count"]))
        if a["stuck"]:
            print("  • CONSTRUÍVEIS MAS PARADAS (%d): %s"
                  % (len(a["stuck"]),
                     ", ".join("%s/%s" % (s["rig"], s["id"]) for s in a["stuck"][:8])))
    else:
        # Fallback display
        ok_r = a.get("_ok_reasons", {})
        print("APROVADAS (fallback story:approved — snapshot indisponível): %d total"
              % a.get("_total_approved", a["total"]))
        print("  • em build agora (in-flight): %d   • held: %d   • mayor-reservada: %d   • recém-despachada: %d"
              % (ok_r.get("in-flight", 0), ok_r.get("held", 0),
                 ok_r.get("mayor", 0), ok_r.get("fresh", 0)))

    if g.get("read_err"):
        print("GATE: ilegível")
    else:
        lp = "—" if g.get("last_pass_min") is None else "há %dmin" % g["last_pass_min"]
        oa = g.get("oldest_active_min")
        oa_s = ("" if not g.get("active")
                else " (mais antigo na fila: %s min)" % (round(oa) if oa is not None else "?"))
        print("GATE: %d ativo(s) na fila%s, %d parked (needs-rebase/error, aguardando autor/humano), último merge %s, reviewer vivo=%s"
              % (len(g.get("active", [])), oa_s, len(g.get("parked", [])),
                 lp, g.get("reviewer_alive")))
    last_sw = p.get("last_sweep_min")
    last_sw_s = ("%.1f" % last_sw) if isinstance(last_sw, float) else str(last_sw)
    print("PILOT vivo=%s (último sweep há %s min)   DOLT responde=%s (%sms)"
          % (p.get("alive"), last_sw_s, d.get("responsive"), d.get("latency_ms")))
    if building_now:
        print("🔨 EM BUILD AGORA (real, todos os stores): %d — %s"
              % (building_now, ", ".join(building_ids[:8])))
    if stalled_ids:
        print("⏸️  %d in-flight mas parado(s) > %.0fh sem atualização → aguardando humano, não building: %s"
              % (len(stalled_ids), DELIVERY_STALL_HOURS, ", ".join(stalled_ids[:8])))
    for n in notes:
        print("ℹ️  " + n)
    print("")

    if fails:
        print("VEREDITO: ❌ NÃO IMPARÁVEL")
        for f in fails:
            print("  ✗ " + f)
        for w in warns:
            print("  ⚠ " + w)
        print("")
        print("→ Isto é uma FALHA REAL. O Mayor deve agir AGORA (não só explicar).")
        sys.exit(1)
    elif warns:
        print("VEREDITO: ⚠️  INCERTO (não posso afirmar ✅ com honestidade)")
        for w in warns:
            print("  ⚠ " + w)
        sys.exit(2)
    else:
        print("VEREDITO: ✅ IMPARÁVEL agora")
        if building_now:
            print("  🔨 Construindo %d agora (%s) — a máquina ESTÁ produzindo, não ociosa."
                  % (building_now, ", ".join(building_ids[:6])))
        if a.get("from_dispatchable") and a["buildable_count"] == 0 and a["parked_count"] > 0:
            print("  Fila inflada com needs-human/on-device/blocked, mas 0 genuinamente construível"
                  " → %s (%d parked)."
                  % ("ocioso correto" if not building_now else "fila dispatchable parqueada (mas há build ativo acima)",
                     a["parked_count"]))
        elif notes:
            print("  Pool saturado (slots cheios) — construíveis na fila normal atrás de capacidade"
                  " (ver nota ℹ️ acima). Alta demanda saudável, não travamento.")
        else:
            print("  Nenhuma construível parada em silêncio; gate fluindo ou ocioso-com-fila-vazia;"
                  " pilot e Dolt vivos.")
        print("  (Lembrete honesto: ✅ significa 'nada travado em silêncio AGORA' — não 'sempre construindo'.")
        print("   Quando o backlog construível-por-código está vazio, ocioso é correto, não falha.)")
        sys.exit(0)


if __name__ == "__main__":
    main()
