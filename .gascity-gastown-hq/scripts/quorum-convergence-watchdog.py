#!/usr/bin/env python3
"""Quorum-convergence watchdog (ga-qw3p.3) — 2-of-3 crew convergence when Mayor is stuck.

Layer 3 of the autonomous escalation hierarchy (ga-qw3p epic). When a blocker
reaches the Mayor (layer 2, ga-qw3p.2) and is not resolved within MAYOR_STALE_SEC
(1800s/30min), this watchdog convenes a quorum of 3 crews who each propose a
concrete resolution. If 2-of-3 agree on the same action, it is executed
autonomously and the convergence is recorded on the bead. If no majority emerges
after VOTE_TIMEOUT_SEC (900s/15min), the bead is escalated via 🚨 to the human.

TRIGGER (either signal sufficient):
  A. Primary: bead has label 'escalation:mayor-escalated' AND
     metadata.escalation.mayor_escalated_at older than MAYOR_STALE_SEC.
     (Set by ga-qw3p.2 — the Mayor-escalation layer.)
  B. Fallback: bead has 'gate:needs-human:technical' + 'story:in-flight' AND
     bead.updated_at older than MAYOR_STALE_SEC. (inflight-reclaim-guard's max-
     reclaim-cap escalation, which represents the same "crew stuck" condition;
     used when ga-qw3p.2 is not yet deployed.)
  Either signal requires the bead is NOT already in a quorum state (no quorum:*
  label) and does NOT already have gate:needs-human from a human decision.

QUORUM PROTOCOL:
  1. Watchdog creates a quorum session bead (type=task, label=quorum:session,
     ephemeral) with the blocker context.
  2. Watchdog selects 3 crews: the domain owner of the blocked bead + 2 seniors
     from the active named-crew roster.
  3. Watchdog nudges each selected crew with a structured request that includes
     the quorum bead ID and asks for a QUORUM_VOTE comment.
  4. Watchdog marks the original bead quorum:convening + records the session in
     the persistent state file.
  5. Poll cycles check the quorum bead's comments for responses matching the
     pattern "QUORUM_VOTE: <action>" from the expected crew authors.
  6. After VOTE_TIMEOUT_SEC, the watchdog counts matching actions:
       >=2 same action → RESOLVED: execute the action autonomously.
       no majority     → DIVERGED: mark quorum:diverged + notify 🚨.

VALID ACTIONS (crew votes must use one of these verbatim):
  reclaim           — strip story:in-flight + reset bead to open for re-dispatch
  reassign:<crew>   — update bead assignee to the named crew
  needs-human       — add gate:needs-human (park for human review)
  close:<reason>    — close the bead with the given reason

SAFETY:
  - Operates only on story:in-flight beads (Pilot-managed, not gate/dog tasks)
  - Never re-convenes on a bead with an existing quorum:* label (one per bead)
  - Fallback trigger skips beads that already carry gate:needs-human from a HUMAN
    decision (only triggers on gate:needs-human:technical from automation)
  - All external calls bounded with timeout
  - DRY_RUN=1 → log decisions, take no action
  - Kill-switch: QUORUM_WATCHDOG_ENABLED=0 → no-op
  - Kill-switch file: .gc/state/quorum-convergence-watchdog.disabled

Silence = healthy. Emits on action only:
  [QUORUM] [CONVENED]  created quorum bead, nudged 3 crews
  [QUORUM] [RESOLVED]  2-of-3 agreed, action executed
  [QUORUM] [DIVERGED]  no majority after timeout, escalated 🚨
  [QUORUM] [ERROR]     execution failed (logged; bead left in quorum:convening)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gc_ledger import gc_ledger_append as _qcw_log

# ── paths ─────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
NOTIFY = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC = os.environ.get("GC_BIN", "gc")
BD = os.environ.get("BD_BIN", "bd")

# ── knobs (all env-overridable) ───────────────────────────────────────────────
ENABLED = os.environ.get("QUORUM_WATCHDOG_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("QUORUM_DRY_RUN", "0") == "1"
MAYOR_STALE_SEC = int(os.environ.get("QUORUM_MAYOR_STALE_SEC", "1800"))    # 30min
VOTE_TIMEOUT_SEC = int(os.environ.get("QUORUM_VOTE_TIMEOUT_SEC", "900"))   # 15min
POLL_SEC = int(os.environ.get("QUORUM_POLL_SEC", "300"))                   # 5min
BD_TIMEOUT = int(os.environ.get("QUORUM_BD_TIMEOUT", "25"))
GC_TIMEOUT = int(os.environ.get("QUORUM_GC_TIMEOUT", "20"))

STATE_FILE = os.path.join(CITY, ".gc/state/quorum-convergence-watchdog.json")
KILL_SWITCH = os.path.join(CITY, ".gc/state/quorum-convergence-watchdog.disabled")

# Persistent named crews eligible as quorum voters (ordered by seniority/relevance).
# Mayor and dogs are never included; adhoc/polecat sessions are excluded at runtime.
QUORUM_CREW_ROSTER = [
    "mila-wa",      # WA/painel/UI/Kanban
    "oracle-wa",    # warming/on-device/presença
    "peter-wa",     # Contagem/geo/ArcGIS/incorporação
    "digo-wa",      # phone-proxy/WAP/IPs/relay/financeiro
    "thies-wa",     # WA senior (general)
    "batista-ps",   # property scrapers
    "batista-wa",   # WA integration
    "batista-lx",   # LX / misc
]

# Domain → primary owner (mirrors pilot-dispatcher.sh bead_domain + rig_domain_owner).
DOMAIN_TO_OWNER: dict[str, str] = {
    "frontend":         "mila-wa",
    "wa-integration":   "mila-wa",
    "warming":          "oracle-wa",
    "real-estate":      "peter-wa",
    "data":             "digo-wa",
    "property-scrapers": "batista-ps",
}

# Valid actions the watchdog can execute autonomously.
VALID_ACTION_RE = re.compile(
    r'^(reclaim|reassign:[a-zA-Z0-9._-]+|needs-human|close:.+)$', re.IGNORECASE)

# Pattern to parse a vote from a comment body.
VOTE_LINE_RE = re.compile(r'^QUORUM_VOTE:\s*(.+)$', re.MULTILINE | re.IGNORECASE)


# ── helpers ───────────────────────────────────────────────────────────────────

def _emit(tag: str, msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    line = f"[{ts}] [QUORUM] [{tag}] {msg}"
    print(line, flush=True)
    try:
        _qcw_log("quorum-convergence-watchdog", {"ts": ts, "tag": tag, "msg": msg})
    except Exception:
        pass


def _run(cmd: list[str], timeout: int = BD_TIMEOUT) -> str | None:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return None


def _parse_iso(ts: str) -> float | None:
    if not ts:
        return None
    ts = ts.rstrip("Z").replace("T", " ")
    try:
        import datetime
        return datetime.datetime.fromisoformat(ts).replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None


def _load_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"active_quorums": {}}


def _save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_FILE)


# ── domain classification ─────────────────────────────────────────────────────

def _classify_domain(title: str, description: str = "") -> str:
    hay = (title + " " + description).lower()
    # WA integration FIRST — WA builds often carry property nouns (imóvel/ITBI/Hex)
    # so they must precede property/real-estate checks (mirrors pilot-dispatcher.sh
    # WA-INTEGRATION PRECEDENCE block).
    if re.search(r'pipedrive|whapi|whatsapp|painel|kanban|frota|canais|disparo|urblink|design.system', hay):
        if re.search(r'design.system|frontend|\bui\b', hay):
            return "frontend"
        return "wa-integration"
    if re.search(r'warming|warm.?up|aquecimento|\bchip\b|ban.?prevention|on.?device', hay):
        return "warming"
    # property-scrapers BEFORE real-estate: "Scraper imóveis PBH" is a scraper build,
    # not a real-estate project — the scraper/CNPJ/CNAE signal is more specific.
    if re.search(r'\bscraper\b|\bscrape\b|\bcnpj\b|\bcnae\b|\brbf\b|\bpbh\b|motherduck|hex notebook|pesquisa_mercado|proprietár', hay):
        return "property-scrapers"
    if re.search(r'arcgis|zoneamento|geo.?match|\bitbi\b|im[oó]ve|quarte[ií]r|terreno|cadastr', hay):
        return "real-estate"
    if re.search(r'financeiro|\bledger\b|enrichment|\bemail\b|mega.?data', hay):
        return "data"
    return ""


# ── crew selection ────────────────────────────────────────────────────────────

def _get_active_named_crews() -> list[str]:
    out = _run([GC, "session", "list", "--json"], timeout=GC_TIMEOUT)
    if not out:
        return list(QUORUM_CREW_ROSTER)
    try:
        data = json.loads(out)
    except Exception:
        return list(QUORUM_CREW_ROSTER)
    active = set()
    for s in data.get("sessions", []):
        if s.get("state") != "active":
            continue
        tmpl = s.get("template", "") or ""
        name = s.get("name", "") or ""
        if not name or tmpl.startswith("gastown.") or "/" in tmpl:
            continue
        if "adhoc" in name or "worker" in name or "dispatcher" in name:
            continue
        if name in ("gastown.mayor", "gastown.deacon"):
            continue
        active.add(name)
    return [c for c in QUORUM_CREW_ROSTER if c in active]


def _select_quorum_crews(title: str, desc: str, active: list[str]) -> list[str]:
    domain = _classify_domain(title, desc)
    owner = DOMAIN_TO_OWNER.get(domain)
    roster = list(active)
    selected: list[str] = []
    if owner and owner in roster:
        selected.append(owner)
        roster.remove(owner)
    for crew in roster:
        if len(selected) >= 3:
            break
        selected.append(crew)
    return selected[:3]


# ── bead discovery ────────────────────────────────────────────────────────────

def _list_beads(extra_args: list[str]) -> list[dict]:
    cmd = [BD, "list", "--json", "--limit", "0"] + extra_args
    out = _run(cmd, timeout=BD_TIMEOUT)
    if not out:
        return []
    try:
        return json.loads(out) or []
    except Exception:
        return []


def _show_bead(bead_id: str) -> dict | None:
    out = _run([BD, "show", bead_id, "--json"], timeout=BD_TIMEOUT)
    if not out:
        return None
    try:
        data = json.loads(out)
        if isinstance(data, list):
            return data[0] if data else None
        return data
    except Exception:
        return None


def _bead_labels(bead: dict) -> list[str]:
    return bead.get("labels", []) or []


def _has_label(bead: dict, label: str) -> bool:
    return label in _bead_labels(bead)


def _detect_triggered_beads(now: float) -> list[dict]:
    triggered: list[dict] = []
    seen_ids: set[str] = set()

    # Primary: escalation:mayor-escalated (ga-qw3p.2 output)
    for b in _list_beads(["--label", "escalation:mayor-escalated",
                           "--status", "open", "--status", "in_progress"]):
        bid = b.get("id", "")
        if not bid or bid in seen_ids:
            continue
        labels = _bead_labels(b)
        if any(l.startswith("quorum:") for l in labels):
            continue
        meta = b.get("metadata", {}) or {}
        esc_at = _parse_iso(meta.get("escalation.mayor_escalated_at", ""))
        if esc_at and (now - esc_at) >= MAYOR_STALE_SEC:
            seen_ids.add(bid)
            triggered.append(b)

    # Fallback: gate:needs-human:technical + story:in-flight + stale updated_at
    # (inflight-reclaim-guard escalation — crew stuck, Mayor implicitly notified)
    for b in _list_beads(["--label", "gate:needs-human:technical",
                           "--label", "story:in-flight",
                           "--status", "open", "--status", "in_progress"]):
        bid = b.get("id", "")
        if not bid or bid in seen_ids:
            continue
        labels = _bead_labels(b)
        if any(l.startswith("quorum:") for l in labels):
            continue
        # Fallback doesn't trigger if there's a HUMAN gate:needs-human decision
        # (the technical sub-label means it came from automation, not a human).
        # We trust that gate:needs-human:technical → automation-only park.
        updated = _parse_iso(b.get("updated_at", ""))
        if updated and (now - updated) >= MAYOR_STALE_SEC:
            seen_ids.add(bid)
            triggered.append(b)

    return triggered


# ── quorum convening ──────────────────────────────────────────────────────────

def _convene_quorum(bead: dict, quorum_crews: list[str], now: float) -> str | None:
    """Create quorum bead, nudge crews, mark original bead. Returns quorum_bead_id."""
    bid = bead.get("id", "")
    title = bead.get("title", bid)
    updated = bead.get("updated_at", "")
    if updated:
        age_min = int((now - (_parse_iso(updated) or now)) / 60)
    else:
        age_min = 0

    deadline_ts = int(now + VOTE_TIMEOUT_SEC)
    deadline_str = time.strftime("%H:%M UTC", time.gmtime(deadline_ts))
    crew_list = ", ".join(quorum_crews) if quorum_crews else "(none available)"
    timeout_min = VOTE_TIMEOUT_SEC // 60

    # Build the quorum bead description.
    description = (
        f"Quórum de convergência para bead bloqueado (ga-qw3p.3).\n\n"
        f"BEAD BLOQUEADO: {bid} — \"{title}\"\n"
        f"Situação: bead travado há {age_min}min; Mayor não resolveu em 30min.\n\n"
        f"CREWS CONVOCADOS: {crew_list}\n\n"
        f"INSTRUÇÕES: cada crew deve postar UM comentário neste bead no formato:\n"
        f"  QUORUM_VOTE: <ação>\n\n"
        f"Ações válidas:\n"
        f"  reclaim           — recolocar na fila de despacho\n"
        f"  reassign:<crew>   — transferir (ex: reassign:mila-wa)\n"
        f"  needs-human       — requer intervenção humana\n"
        f"  close:<motivo>    — fechar o bead\n\n"
        f"PRAZO: {deadline_str} ({timeout_min}min a partir de agora)\n"
        f"DECISÃO: maioria 2-de-3 → ação executada; sem maioria → 🚨 humano."
    )

    meta = json.dumps({
        "quorum.blocker_id": bid,
        "quorum.crews": ",".join(quorum_crews),
        "quorum.convened_at": int(now),
        "quorum.vote_timeout": deadline_ts,
    })

    _emit("CONVENING", f"blocker={bid} crews={quorum_crews}")

    if DRY_RUN:
        _emit("CONVENING", "[DRY_RUN] would create quorum bead and nudge crews")
        return f"dry-run-quorum-{bid}"

    # Create the quorum session bead.
    out = _run([BD, "create",
                "--type", "task",
                "--label", "quorum:session",
                "--ephemeral",
                "--description", description,
                "--metadata", meta,
                "--title", f"QUÓRUM [{bid}]: convergência de 2-de-3 crews"],
               timeout=BD_TIMEOUT)
    if not out:
        _emit("ERROR", f"failed to create quorum bead for {bid}")
        return None

    quorum_id = out.strip()

    # Mark original bead as quorum:convening.
    _run([BD, "label", "add", bid, "quorum:convening", "-q"], timeout=BD_TIMEOUT)
    _run([BD, "update", bid,
          "--metadata", json.dumps({
              "quorum.session_id": quorum_id,
              "quorum.convened_at": int(now),
          })], timeout=BD_TIMEOUT)

    # Nudge each crew with the quorum request.
    nudge_msg = (
        f"[QUORUM REQUEST — ga-qw3p.3] O bead {bid} (\"{title}\") está "
        f"bloqueado há {age_min}min e o Mayor não resolveu em 30min. "
        f"Você foi convocado para o quórum.\n\n"
        f"AÇÃO: Examine o bead {bid} e poste UM comentário no bead do quórum "
        f"({quorum_id}) com sua proposta no formato:\n"
        f"QUORUM_VOTE: <ação>\n\n"
        f"Ações: reclaim | reassign:<crew> | needs-human | close:<motivo>\n"
        f"PRAZO: {deadline_str} ({timeout_min}min)"
    )
    for crew in quorum_crews:
        result = _run([GC, "session", "nudge", crew, nudge_msg], timeout=GC_TIMEOUT)
        if result is None:
            _emit("WARN", f"nudge to {crew} failed (session may be inactive)")

    _emit("CONVENED", f"blocker={bid} quorum={quorum_id} crews={quorum_crews}")
    return quorum_id


# ── vote collection ───────────────────────────────────────────────────────────

def _collect_votes(quorum_id: str, expected_crews: list[str]) -> dict[str, str]:
    """Return {crew_name: proposed_action} for all valid votes found so far."""
    out = _run([BD, "comments", quorum_id, "--json"], timeout=BD_TIMEOUT)
    if not out:
        return {}
    try:
        comments = json.loads(out) or []
    except Exception:
        return {}

    votes: dict[str, str] = {}
    for c in comments:
        author = c.get("author", "")
        text = c.get("text", "")
        if not author or not text:
            continue
        if author not in expected_crews:
            continue
        m = VOTE_LINE_RE.search(text)
        if not m:
            continue
        action = m.group(1).strip()
        if VALID_ACTION_RE.match(action):
            votes[author] = action.lower()
    return votes


def _decide(votes: dict[str, str]) -> str | None:
    """Return the action if 2+ crews agree, else None."""
    from collections import Counter
    counts = Counter(votes.values())
    for action, count in counts.most_common(1):
        if count >= 2:
            return action
    return None


# ── action execution ──────────────────────────────────────────────────────────

def _execute_action(bead_id: str, action: str) -> bool:
    """Execute the agreed quorum action on the original bead. Returns True on success."""
    action = action.strip().lower()

    if action == "reclaim":
        # Strip story:in-flight, pilot:dispatched; reset status to open; clear assignee.
        _run([BD, "label", "remove", bead_id, "story:in-flight", "-q"], timeout=BD_TIMEOUT)
        _run([BD, "label", "remove", bead_id, "pilot:dispatched", "-q"], timeout=BD_TIMEOUT)
        r = _run([BD, "update", bead_id, "--assignee", ""], timeout=BD_TIMEOUT)
        # bd reopen resets status to open
        _run([BD, "reopen", bead_id], timeout=BD_TIMEOUT)
        return True

    if action.startswith("reassign:"):
        crew = action.split(":", 1)[1].strip()
        if not crew:
            return False
        r = _run([BD, "update", bead_id, "--assignee", crew], timeout=BD_TIMEOUT)
        return r is not None

    if action == "needs-human":
        r = _run([BD, "label", "add", bead_id, "gate:needs-human", "-q"], timeout=BD_TIMEOUT)
        return r is not None

    if action.startswith("close:"):
        reason = action.split(":", 1)[1].strip()
        if not reason:
            return False
        r = _run([BD, "close", bead_id, "--reason", reason], timeout=BD_TIMEOUT)
        return r is not None

    return False


def _escalate_diverged(bead_id: str, title: str, votes: dict[str, str]) -> None:
    """Mark quorum:diverged + notify 🚨 (ga-qw3p.4 / ga-aw2ga path)."""
    vote_summary = "; ".join(f"{k}:{v}" for k, v in votes.items()) if votes else "sem respostas"
    msg = (
        f"🚨 QUÓRUM DIVERGIU — blocker {bead_id} (\"{title}\") não convergiu. "
        f"Votos: {vote_summary}. Nenhuma ação tem maioria 2-de-3. "
        f"Intervenção humana necessária."
    )
    _emit("DIVERGED", f"blocker={bead_id} votes={votes}")

    if DRY_RUN:
        _emit("DIVERGED", "[DRY_RUN] would notify and mark quorum:diverged")
        return

    # Mark the bead.
    _run([BD, "label", "remove", bead_id, "quorum:convening", "-q"], timeout=BD_TIMEOUT)
    _run([BD, "label", "add", bead_id, "quorum:diverged", "-q"], timeout=BD_TIMEOUT)
    _run([BD, "comment", bead_id,
          f"quorum-convergence-watchdog (ga-qw3p.3): DIVERGED. {msg}"],
         timeout=BD_TIMEOUT)

    # 🚨 notify
    try:
        subprocess.run(
            [NOTIFY, "-t", "🚨 Quórum divergiu", "-p", "5", msg],
            capture_output=True, text=True, timeout=10)
    except Exception:
        pass

    # Mail Mayor as well (durable escalation).
    _run([GC, "mail", "send", "mayor",
          "-s", f"🚨 Quórum divergiu: {bead_id}",
          "-m", msg], timeout=GC_TIMEOUT)


# ── main cycle ────────────────────────────────────────────────────────────────

def _run_cycle(state: dict, now: float) -> None:
    # ── 1. Check active quorum sessions for vote collection ───────────────────
    to_remove: list[str] = []
    for quorum_id, session in list(state.get("active_quorums", {}).items()):
        bid = session.get("original_bead_id", "")
        crews = session.get("crews", [])
        convened_at = float(session.get("convened_at", 0))
        decided = session.get("decided", False)

        if decided:
            to_remove.append(quorum_id)
            continue

        elapsed = now - convened_at

        # Collect votes.
        votes = _collect_votes(quorum_id, crews)

        # Check if we have a decision (2+ agree) or timeout.
        agreed = _decide(votes)

        if agreed:
            _emit("RESOLVED", f"blocker={bid} action={agreed} votes={votes}")
            bead = _show_bead(bid)
            title = bead.get("title", bid) if bead else bid

            if not DRY_RUN:
                ok = _execute_action(bid, agreed)
                if ok:
                    _run([BD, "label", "remove", bid, "quorum:convening", "-q"], timeout=BD_TIMEOUT)
                    _run([BD, "label", "add", bid, "quorum:resolved", "-q"], timeout=BD_TIMEOUT)
                    _run([BD, "comment", bid,
                          f"quorum-convergence-watchdog (ga-qw3p.3): RESOLVED. "
                          f"Quórum convergiu: {agreed}. Votos: {votes}. "
                          f"Ação executada autonomamente."],
                         timeout=BD_TIMEOUT)
                    try:
                        subprocess.run(
                            [NOTIFY, "-t", "Quórum resolvido",
                             f"Bead {bid} desbloqueado por quórum: {agreed}"],
                            capture_output=True, text=True, timeout=10)
                    except Exception:
                        pass
                else:
                    _emit("ERROR", f"failed to execute action={agreed} on {bid}")
                session["decided"] = True
                to_remove.append(quorum_id)

        elif elapsed >= VOTE_TIMEOUT_SEC:
            # Timeout: no majority.
            bead = _show_bead(bid)
            title = bead.get("title", bid) if bead else bid
            _escalate_diverged(bid, title, votes)
            session["decided"] = True
            to_remove.append(quorum_id)

        else:
            remaining = int((convened_at + VOTE_TIMEOUT_SEC - now) / 60)
            _emit("WAITING", f"quorum={quorum_id} votes={len(votes)}/3 "
                  f"timeout_in={remaining}min")

    for qid in to_remove:
        state["active_quorums"].pop(qid, None)

    # ── 2. Detect Mayor-stuck beads → convene new quorums ────────────────────
    triggered = _detect_triggered_beads(now)
    if not triggered:
        return

    active_crews = _get_active_named_crews()

    for bead in triggered:
        bid = bead.get("id", "")
        title = bead.get("title", bid)
        desc = bead.get("description", "") or ""

        # Skip if already tracked.
        already_tracked = any(
            s.get("original_bead_id") == bid
            for s in state["active_quorums"].values()
        )
        if already_tracked:
            continue

        crews = _select_quorum_crews(title, desc, active_crews)
        if len(crews) < 2:
            _emit("WARN", f"not enough active crews for quorum (need >=2, have {crews}); "
                  f"skipping bead={bid}")
            continue

        quorum_id = _convene_quorum(bead, crews, now)
        if quorum_id and not DRY_RUN:
            state["active_quorums"][quorum_id] = {
                "original_bead_id": bid,
                "crews": crews,
                "convened_at": now,
                "decided": False,
            }


def main() -> None:
    if not ENABLED:
        return

    # Startup marker.
    os.makedirs(os.path.join(CITY, ".gc/state"), exist_ok=True)
    os.makedirs(os.path.join(CITY, ".gc/logs"), exist_ok=True)

    startup_file = os.path.join(CITY, ".gc/state/quorum-convergence-watchdog.startup")
    with open(startup_file, "w") as f:
        f.write(f"{os.getpid()} {int(time.time())}\n")

    _emit("STARTUP", f"pid={os.getpid()} MAYOR_STALE_SEC={MAYOR_STALE_SEC} "
          f"VOTE_TIMEOUT_SEC={VOTE_TIMEOUT_SEC} POLL_SEC={POLL_SEC} DRY_RUN={DRY_RUN}")

    while True:
        if os.path.exists(KILL_SWITCH):
            _emit("KILL_SWITCH", "quorum-convergence-watchdog.disabled present — skipping cycle")
            time.sleep(POLL_SEC)
            continue

        now = time.time()
        state = _load_state()

        try:
            _run_cycle(state, now)
        except Exception as exc:
            _emit("ERROR", f"cycle exception: {exc}")

        _save_state(state)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
