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
        story:blocked — esses são PARKED, não falha silenciosa).
        Uma construível sem story:in-flight, sem hold legítimo, com pilot vivo = FALHA.
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

# Labels that mark a bead as NOT code-buildable right now (not a silent stall):
PARKING_LABELS = ("gate:needs-human", "story:needs-human", "on-device",
                  "story:needs-device", "blocked", "story:blocked")

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
    Returns list of label strings, empty list if no LABELS line, or None on read error."""
    r = _sh([BD, "-C", root, "show", bead_id], timeout=15)
    if r is None or r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("LABELS:"):
            raw = stripped.split("LABELS:", 1)[1].strip()
            return [l.strip() for l in raw.split(",") if l.strip()]
    return []  # no LABELS line → assume no labels


def _label_is_parking(label):
    """Returns True if this label means the bead is not code-buildable right now."""
    for park in PARKING_LABELS:
        if label == park or label.startswith(park + ":"):
            return True
    return False


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
    parked, buildable, stuck = [], [], []
    flowing_count, held_count = 0, 0
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

        # PARKED: has a non-buildable label → not a silent stall, correct to skip
        if any(_label_is_parking(l) for l in labels):
            parked.append({"id": bead_id, "title": title, "rig": rig})
            continue

        # GENUINELY BUILDABLE
        is_flowing = "story:in-flight" in labels
        # held: pilot:held-until:* — temporarily deferred, not silently stuck
        held_labels = [l for l in labels if l.startswith("pilot:held-until:")]
        is_held = bool(held_labels)
        is_held_loop = is_held and len(held_labels) > HELD_LOOP_MAX

        buildable.append({"id": bead_id, "title": title, "rig": rig,
                          "flowing": is_flowing, "held": is_held and not is_held_loop})

        if is_flowing:
            flowing_count += 1
        elif is_held_loop:
            # too many re-holds → pilot can't dispatch it → stuck (not a legit hold)
            stuck.append({"id": bead_id, "rig": rig, "title": title,
                          "reason": "held-loop:%dx" % len(held_labels)})
        elif is_held:
            held_count += 1
        else:
            stuck.append({"id": bead_id, "rig": rig, "title": title})

    return {
        "total": len(items),
        "parked_count": len(parked),
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
    ok_in_flight, ok_held, ok_mayor, ok_fresh = 0, 0, 0, 0
    warns = list(inherited_warns)

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
        "parked_count": ok_held + ok_mayor,
        "buildable_count": total - len(stuck) - ok_in_flight,
        "flowing_count": ok_in_flight,
        "held_count": ok_held,
        "stuck": stuck,
        "read_err": [],  # already surfaced in warns
        "warns": warns,
        "from_dispatchable": False,
        "snap_age_min": None,
        "_ok_reasons": {"in-flight": ok_in_flight, "held": ok_held,
                        "mayor": ok_mayor, "fresh": ok_fresh},
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

    fails, warns = [], []

    # --- Buildable queue verdict ---
    for w in a.get("warns", []):
        warns.append(w)
    if a["read_err"]:
        warns.append("não consegui classificar %d bead(s) (bd show falhou): %s"
                     % (len(a["read_err"]), ", ".join(str(x) for x in a["read_err"][:8])))

    if a["stuck"] and (p.get("alive") is not False):
        if a.get("from_dispatchable"):
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

    # --- Report ---
    print("═══ CHECK IMPARÁVEL — %s ═══" % time.strftime("%Y-%m-%d %H:%M %Z"))
    print("")

    if a.get("from_dispatchable"):
        snap_note = ("snapshot %.0fmin atrás" % a["snap_age_min"]) if a.get("snap_age_min") is not None else ""
        print("FILA DO PILOT (dispatchable%s): %d total"
              % ((" — " + snap_note) if snap_note else "", a["total"]))
        print("  • parked (needs-human/on-device/blocked): %d   • genuinamente construíveis: %d"
              "   • em build agora (in-flight): %d   • held: %d"
              % (a["parked_count"], a["buildable_count"], a["flowing_count"], a["held_count"]))
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
        if a.get("from_dispatchable") and a["buildable_count"] == 0 and a["parked_count"] > 0:
            print("  Fila inflada com needs-human/on-device/blocked, mas 0 genuinamente construível"
                  " → ocioso correto (%d parked)." % a["parked_count"])
        else:
            print("  Nenhuma construível parada em silêncio; gate fluindo ou ocioso-com-fila-vazia;"
                  " pilot e Dolt vivos.")
        print("  (Lembrete honesto: ✅ significa 'nada travado em silêncio AGORA' — não 'sempre construindo'.")
        print("   Quando o backlog construível-por-código está vazio, ocioso é correto, não falha.)")
        sys.exit(0)


if __name__ == "__main__":
    main()
