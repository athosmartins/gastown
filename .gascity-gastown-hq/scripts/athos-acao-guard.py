#!/usr/bin/env python3
"""athos.acao coverage guard (ga-ypwdug).

Detects beads that qualify for Athos's 👤 Sua vez queue in
painel_visibilidade.py (whatsapp_automation/daemons/painel_visibilidade.py's
_travada_reason, lines ~1744-2040, plus the story:needs-approval/
refino:policy-gap conveyor lane it shares with bead_state.py's
ATHOS_TURN/is_athos_page) but carry no `athos.acao` metadata — the field
_athos_acao() reads to render "O QUE VOCÊ FAZ". Missing it, the panel shows
"⚠️ ninguém escreveu o que você precisa fazer aqui" and disables the conclude
button (wa-sowus), leaving Athos unable to act on his own card.

ga-ypwdug (14-15/08/2026): REGRA Nº 3 (town-deltas CLAUDE.md) mandates writing
this field but, until this same bug's other half (branch
fix/ga-acao-campo-nomeado, gate marker ga-xt8zrf) fixed the doctrine text,
never named which metadata KEY to write — 26/26 beads in Athos's queue had the
warning, including one filed by the same author who had just merged the rule.
Doctrine text alone does not enforce adherence; this script is the missing
MECHANISM half of that bug's acceptance bar ("um guard que impeça o 27º de
entrar sem [athos.acao]"). Confirmed by direct grep of the whole workspace
(2026-08-15): no prior guard/lint/daemon checked this at any point before a
bead reaches the panel — the only existing signal was the client-side
render-time warning above, which fires AFTER the bead is already on Athos's
screen. This script catches it within one poll cycle instead.

WHY A UNION OF TWO SOURCES, NOT ONE: painel_visibilidade.py's own
_travada_reason (operative — this is what actually renders "turn": "athos"
on screen today) and bead_state.py's ATHOS_TURN/is_athos_page (the
"canonical" layer painel imports for the needs-approval conveyor + Travadas
rescue pass) DISAGREE on one predicate: bead_state.derive()'s rule 10
explicitly does NOT treat exec:manual+no-assignee as Athos's turn (routes it
to "mayor" instead, with the comment "'não sei quem' NÃO é 'o Athos faz'"),
while _travada_reason DOES (lines 1904-1919, wa-w7pds) — and that clause is
the operative one: 4 of the first 6 beads this bug's cleanup pass found
missing athos.acao (2026-08-15) were exactly this category. A guard built on
bead_state.is_athos_page() alone would have missed all four — reproducing
the exact bug it exists to close. IS_SUA_VEZ_ACAO_GAP below is therefore a
manually-reconciled union of both sources' turn=="athos"/is_athos_page
predicates, not a re-derivation from either single one — see
docs/pending-engine-window or a follow-up bead for reconciling the
discrepancy itself, which is out of scope here (filed separately; this
script does not attempt to fix bead_state.py's classification).

DELIBERATELY DOES NOT auto-fill athos.acao. The field requires judgment — a
guessed instruction derived from title/description would carry the same
confident look as a real one and could tell Athos to do the WRONG thing
(_athos_acao's own docstring makes exactly this argument; the bead's body
independently repeats it verbatim as a hard constraint). Detection +
durable, self-clearing visibility only.

Poll loop (default 900s/15min, ATHOS_ACAO_GUARD_POLL_SEC env override).
Silence = healthy (no gaps found, or every found gap already flagged in a
prior cycle). Emits (print + notify) only on a state CHANGE:
  [ATHOS-ACAO-GUARD] [FLAGGED]  <rig>/<id> newly missing athos.acao, marker label applied
  [ATHOS-ACAO-GUARD] [RESOLVED] <rig>/<id> athos.acao filled (or no longer Sua-vez-eligible), marker removed
  [ATHOS-ACAO-GUARD] [STARTUP]  initial snapshot

Marker label: athos-acao:missing — applied the FIRST cycle a gap is found so
repeat cycles never re-alert the same bead (idempotent, matches this city's
established shield/marker-label convention), removed the cycle athos.acao is
observed non-empty OR the bead no longer qualifies (status settled, label
changed) — so the marker never outlives the gap it describes and never
becomes permanent noise on a resolved card.

Safety invariants:
  - Read-only against bead CONTENT: never writes/guesses athos.acao itself.
  - The only mutations are add/remove of the single marker label above.
  - Fails safe on every query: a rig-enumeration or per-rig query failure
    skips that rig/cycle (never treated as "zero gaps found").
  - Never crashes the loop: any exception in a cycle is caught, logged, and
    the loop continues on the next poll.
"""
import json
import os
import subprocess
import sys as _sys
import time

GC_CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
POLL_SEC = int(os.environ.get("ATHOS_ACAO_GUARD_POLL_SEC", "900"))  # 15min
NOTIFY_BIN = "/Users/athos/.local/bin/notify"

MARKER_LABEL = "athos-acao:missing"

# bd's --status filter takes an explicit allowlist (matches this codebase's
# established "explicit status filter, never rely on the open-only default"
# convention — see inflight-reclaim-guard.py's ga-vw26y note). These are every
# non-terminal status a Sua-vez-eligible bead can carry; "closed" is the only
# terminal one that matters here (painel's own _STATUS_SETTLED gate).
NON_TERMINAL_STATUSES = ("open", "in_progress", "deferred", "blocked")

# blocked-reason:decision / :feasibility — painel_visibilidade.py's
# _BLOCKED_REASON_ATHOS (line 408).
ATHOS_DECISION_LABELS = frozenset({"blocked-reason:decision", "blocked-reason:feasibility"})


def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash on failure)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            [NOTIFY_BIN, "-t", "athos.acao guard", "-p", "3", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


def _list_rig_stores():
    """Return [(name, path), ...] for EVERY rig including HQ, or None on failure.

    Unlike inflight-reclaim-guard.py's helper of the same name (which
    excludes HQ because its caller queries HQ separately via a plain,
    cwd-relative `bd`), this guard treats every rig uniformly through
    `bd -C <path>` — one code path, no reliance on process cwd, which
    sidesteps the cwd-reset trap a `cd`+bare-`bd` split would risk in a
    long-running loop. HQ's own path comes from GC_CITY_PATH, the same
    value the plist sets.
    """
    try:
        result = subprocess.run(
            ["gc", "--city", GC_CITY, "rig", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        rigs = data.get("rigs", [])
        out = [(r.get("name", ""), r["path"]) for r in rigs
               if r.get("path") and os.path.isdir(r.get("path", ""))]
        if not any(os.path.normpath(p) == os.path.normpath(GC_CITY) for _, p in out):
            out.append(("gascity", GC_CITY))
        return out
    except Exception:
        return None


def is_sua_vez_acao_gap(labels, assignee, athos_acao):
    """True iff this bead renders in painel's 👤 Sua vez AND athos.acao is empty.

    Pure predicate — the reconciled union described in the module docstring.
    Mirrors _travada_reason's turn=="athos" branches (painel_visibilidade.py,
    ~lines 1839-1842 / 1904-1919 / 1965-1968) plus the story:needs-approval /
    refino:policy-gap conveyor-lane check (bead_state.py's ATHOS_TURN).
    """
    if (athos_acao or "").strip():
        return False
    lset = set(labels or [])
    if lset & ATHOS_DECISION_LABELS:
        return True
    if "exec:manual" in lset and not (assignee or "").strip():
        return True
    if any(str(l).startswith("next-action:") and "athos" in str(l) for l in lset):
        return True
    if "story:needs-approval" in lset:
        return True
    if "refino:policy-gap" in lset:
        return True
    return False


def _bd(rig_path, *args, timeout=20):
    cmd = ["bd"]
    if rig_path and os.path.normpath(rig_path) != os.path.normpath(GC_CITY):
        cmd += ["-C", rig_path]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def scan_rig(rig_path):
    """Return (gaps, resolved) bead-id lists for one rig store, or None on error.

    gaps: Sua-vez-eligible, athos.acao empty, marker label NOT yet applied
          (i.e. a genuinely NEW finding this cycle).
    resolved: marker label IS present, but athos.acao is now filled OR the
          bead no longer qualifies (status settled / labels changed) — the
          marker should be removed so it never outlives the gap.
    Already-flagged-and-still-a-gap beads are intentionally excluded from
    both lists: they need no action this cycle (silence = healthy).
    """
    try:
        r = _bd(rig_path, "list", "--status", ",".join(NON_TERMINAL_STATUSES),
                "--json", "--limit", "0", timeout=45)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        data = json.loads(r.stdout)
        if not isinstance(data, list):
            return None
    except Exception:
        return None

    gaps, resolved = [], []
    for b in data:
        bid = b.get("id", "")
        if not bid:
            continue
        labels = b.get("labels") or []
        assignee = b.get("assignee") or ""
        acao = (b.get("metadata") or {}).get("athos.acao")
        has_marker = MARKER_LABEL in labels
        qualifies_gap = is_sua_vez_acao_gap(labels, assignee, acao)
        if qualifies_gap and not has_marker:
            gaps.append(bid)
        elif has_marker and not qualifies_gap:
            resolved.append(bid)
    return gaps, resolved


def run_cycle():
    rigs = _list_rig_stores()
    if rigs is None:
        print("[ATHOS-ACAO-GUARD] cycle: rig enumeration failed, skipping", flush=True)
        return 0, 0

    total_gaps = 0
    total_resolved = 0
    for rig_name, rig_path in rigs:
        result = scan_rig(rig_path)
        if result is None:
            print(f"[ATHOS-ACAO-GUARD] {rig_name}: query failed, skipping", flush=True)
            continue
        gaps, resolved = result
        for bid in gaps:
            r = _bd(rig_path, "label", "add", bid, MARKER_LABEL, timeout=15)
            if r.returncode == 0:
                emit(f"[ATHOS-ACAO-GUARD] [FLAGGED] {rig_name}/{bid} missing athos.acao "
                     f"— labeled {MARKER_LABEL}")
                total_gaps += 1
            else:
                print(f"[ATHOS-ACAO-GUARD] [FLAG-FAILED] {rig_name}/{bid}: "
                      f"{r.stderr.strip()[:200]}", flush=True)
        for bid in resolved:
            r = _bd(rig_path, "label", "remove", bid, MARKER_LABEL, timeout=15)
            if r.returncode == 0:
                print(f"[ATHOS-ACAO-GUARD] [RESOLVED] {rig_name}/{bid} athos.acao now set "
                      f"— marker removed", flush=True)
                total_resolved += 1
            else:
                print(f"[ATHOS-ACAO-GUARD] [RESOLVE-FAILED] {rig_name}/{bid}: "
                      f"{r.stderr.strip()[:200]}", flush=True)
    return total_gaps, total_resolved


def main():
    print(f"[ATHOS-ACAO-GUARD] [STARTUP] poll={POLL_SEC}s marker={MARKER_LABEL}", flush=True)
    while True:
        try:
            gaps, resolved = run_cycle()
            print(f"[ATHOS-ACAO-GUARD] cycle: flagged={gaps} resolved={resolved}", flush=True)
        except Exception as exc:
            # Never crash the guard loop.
            print(f"[ATHOS-ACAO-GUARD] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


def _selftest():
    """Pure-function regression tests for is_sua_vez_acao_gap(). No bd/gc calls."""
    cases = [
        # (labels, assignee, athos_acao, expected, description)
        (["blocked-reason:decision"], "", None, True, "blocked-reason:decision, no acao"),
        (["blocked-reason:decision"], "", "algo", False, "blocked-reason:decision, acao set"),
        (["blocked-reason:feasibility"], "", "", True, "blocked-reason:feasibility, empty-string acao"),
        (["exec:manual"], "", None, True, "exec:manual orphan (wa-jyskd/wa-e8efn/wa-8key3/wa-yyv3j shape)"),
        (["exec:manual"], "oracle-wa", None, False, "exec:manual WITH assignee is not Athos's turn"),
        (["exec:manual"], "", "Nada a decidir", False, "exec:manual orphan, acao already filled"),
        (["next-action:athos-e-oracle"], "", None, True, "next-action:athos* prefix match"),
        (["next-action:oracle-investiga"], "", None, False, "next-action: NOT athos (wa-yyv3j's own label)"),
        (["story:needs-approval"], "", None, True, "story:needs-approval (wa-lzt1z shape)"),
        (["refino:policy-gap"], "", None, True, "refino:policy-gap (bead_state.ATHOS_TURN)"),
        (["ctx:ready", "exec:auto"], "", None, False, "ordinary dispatchable bead, no Athos signal"),
        ([], "", None, False, "no labels at all"),
        (["exec:manual"], "  ", None, True, "whitespace-only assignee counts as unassigned"),
    ]
    failures = []
    for labels, assignee, acao, expected, desc in cases:
        got = is_sua_vez_acao_gap(labels, assignee, acao)
        if got != expected:
            failures.append(f"FAIL: {desc} — labels={labels} assignee={assignee!r} "
                             f"acao={acao!r} expected={expected} got={got}")
    if failures:
        for f in failures:
            print(f, flush=True)
        print(f"[ATHOS-ACAO-GUARD] [SELFTEST] {len(failures)}/{len(cases)} FAILED", flush=True)
        return False
    print(f"[ATHOS-ACAO-GUARD] [SELFTEST] {len(cases)}/{len(cases)} passed", flush=True)
    return True


if __name__ == "__main__":
    if "--selftest" in _sys.argv:
        ok = _selftest()
        _sys.exit(0 if ok else 1)
    if "--once" in _sys.argv:
        gaps, resolved = run_cycle()
        print(f"[ATHOS-ACAO-GUARD] single cycle: flagged={gaps} resolved={resolved}", flush=True)
        _sys.exit(0)
    main()
