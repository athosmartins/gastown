#!/usr/bin/env python3
"""
imparavel-check — O teste FALSIFICÁVEL de "está imparável?".

Athos não roda código. Quando ele pergunta "está imparável?", o Mayor roda ISTO
e traz o veredito honesto. Este script NÃO dá opinião — mede a definição:

  IMPARÁVEL (def. A — a única atingível) =
    (1) NENHUMA bead story:approved está parada em silêncio
        (toda aprovada: ou está fluindo pro build, ou foi roteada pro estado
         verdadeiro, ou está held, ou é mayor-reservada). Uma aprovada parada
         há > STARVE_MIN com o pilot vivo, sem nada disso = FALHA.
    (2) O gate não está travado em silêncio
        (se há marker queued/dispatching, tem que haver progresso: um merge
         recente OU um reviewer vivo. needs-rebase/error = PARKED, não é stall.)
    (3) O pilot (dispatcher) está vivo.
    (4) O Dolt responde.

  Princípio: na dúvida, FLAGA (nunca um ✅ falso). Melhor apontar um não-problema
  que esconder um stall real. Saída: relatório em PT + 'VEREDITO: ...' + exit 0/1.
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

STARVE_MIN = int(os.environ.get("IMP_STARVE_MIN", "20"))      # aprovada parada além disso = stuck
GATE_STALL_MIN = int(os.environ.get("IMP_GATE_STALL_MIN", "165"))  # 0 merges nessa janela + fila + sem reviewer = stall
PILOT_DEAD_MIN = int(os.environ.get("IMP_PILOT_DEAD_MIN", "20"))   # pilot sem sweep além disso = morto

# Labels que justificam uma aprovada NÃO estar em build agora (não é silêncio):
ROUTED_OUT = ("story:needs-device", "story:needs-human", "story:blocked")
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
    for fmt in (None,):  # try fromisoformat first
        try:
            import datetime
            dt = datetime.datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return max(0.0, (NOW - dt.timestamp()) / 60.0)
        except Exception:
            break
    return None


def _labels(b):
    l = b.get("labels", []) or []
    return l if isinstance(l, list) else []


# ── CHECK 1: approved work silently stuck ────────────────────────────────────
def check_approved():
    stuck, total, ok_reasons = [], 0, {"in-flight": 0, "held": 0, "mayor": 0, "fresh": 0}
    read_err = []
    for name, root in RIGS:
        beads, ok = _bd_json(root, "story:approved")
        if not ok:
            read_err.append(name)
            continue
        for b in beads:
            total += 1
            labs = _labels(b)
            ls = " ".join(labs)
            asg = (b.get("assignee") or "")
            if "story:in-flight" in labs:
                ok_reasons["in-flight"] += 1; continue
            if any(l.startswith("pilot:held-until") for l in labs):
                ok_reasons["held"] += 1; continue
            if asg == "mayor":
                ok_reasons["mayor"] += 1; continue
            if any(r in ls for r in ROUTED_OUT):
                continue  # mislabeled but already routed — reconciler will clean story:approved
            age = _age_min(b.get("updated_at"))
            if age is not None and age <= STARVE_MIN:
                ok_reasons["fresh"] += 1; continue  # just dispatched / transient
            # story:approved, not flowing, not held, not mayor, not routed, and stale → STUCK
            stuck.append({"rig": name, "id": b.get("id"),
                          "title": (b.get("title", "") or "")[:55],
                          "age_min": round(age) if age is not None else "?"})
    return {"total": total, "stuck": stuck, "ok_reasons": ok_reasons, "read_err": read_err}


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
    # Stall if EITHER:
    #  (a) an active marker has been queued/dispatching longer than GATE_STALL_MIN —
    #      a marker should not sit that long; this catches a FROZEN reviewer that reads
    #      'active' in gc session list but is not progressing (the ga-q8tmn blind spot), OR
    #  (b) no merge in the window AND no live reviewer at all (nothing is working it).
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
    if a["stuck"] and (p.get("alive") is not False):
        fails.append("%d bead(s) APROVADA(s) parada(s) em silêncio (pilot vivo, não construindo, não roteada): %s"
                     % (len(a["stuck"]), ", ".join("%s/%s (%smin)" % (s["rig"], s["id"], s["age_min"]) for s in a["stuck"][:6])))
    if a["read_err"]:
        warns.append("não consegui ler story:approved de: %s (Dolt/bd) — investigar, não posso afirmar ✅" % ", ".join(a["read_err"]))
    if g.get("read_err"):
        warns.append("não consegui ler os gate markers — investigar")
    elif g.get("stalled"):
        fails.append("GATE travado: %d marker(s) na fila — %s"
                     % (len(g["active"]), g.get("stall_reason", "sem progresso")))
    if p.get("alive") is False:
        fails.append("PILOT (dispatcher) MORTO: último sweep há %s min" % p.get("last_sweep_min"))
    if not d.get("responsive"):
        fails.append("DOLT não responde (bd query falhou) — coletar diagnóstico antes de reiniciar")

    print("═══ CHECK IMPARÁVEL — %s ═══" % time.strftime("%Y-%m-%d %H:%M %Z"))
    print("")
    # positive evidence
    okr = a["ok_reasons"]
    print("APROVADAS (fila de código): %d total" % a["total"])
    print("  • em build agora (in-flight): %d   • held (temporário): %d   • mayor-reservada: %d   • recém-despachada: %d"
          % (okr["in-flight"], okr["held"], okr["mayor"], okr["fresh"]))
    if g.get("read_err"):
        print("GATE: ilegível")
    else:
        lp = "—" if g.get("last_pass_min") is None else "há %dmin" % g["last_pass_min"]
        oa = g.get("oldest_active_min")
        oa_s = "" if not g.get("active") else " (mais antigo na fila: %s min)" % (round(oa) if oa is not None else "?")
        print("GATE: %d ativo(s) na fila%s, %d parked (needs-rebase/error, aguardando autor/humano), último merge %s, reviewer vivo=%s"
              % (len(g.get("active", [])), oa_s, len(g.get("parked", [])), lp, g.get("reviewer_alive")))
    print("PILOT vivo=%s (último sweep há %s min)   DOLT responde=%s (%sms)"
          % (p.get("alive"), p.get("last_sweep_min"), d.get("responsive"), d.get("latency_ms")))
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
        print("  Nenhuma aprovada parada em silêncio; gate fluindo ou ocioso-com-fila-vazia; pilot e Dolt vivos.")
        print("  (Lembrete honesto: ✅ significa 'nada travado em silêncio AGORA' — não 'sempre construindo'.")
        print("   Quando o backlog construível-por-código está vazio, ocioso é correto, não falha.)")
        sys.exit(0)


if __name__ == "__main__":
    main()
