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

GATE FIX (ga-96xden, 2026-08-15, gate attempt 2/3 FAIL): is_sua_vez_acao_gap's
exec:manual-orphan and next-action:athos* clauses used to fire independently of
everything else, but in the real _travada_reason neither is independently
sufficient — each sits behind an earlier, higher-precedence branch (blocked
status/labels, gate-fix, gate-needs-rebase, gate-passed+in-flight, needs-human,
reclaim-capped, pool-refused, phone-proxy — plus, for next-action specifically,
exec:manual itself, no-auto-dispatch, engine-window, awaiting-external-merge)
that returns turn:"other" FIRST. A bead carrying exec:manual+no-assignee AND a
stale gate:needs-fix renders in 🔒 Travadas in the real panel, never 👤 Sua vez
— the old code flagged it as a gap anyway (false positive: spurious marker
label + push notification, violating this module's own "Silence = healthy"
invariant). Fixed by threading bd `status` through and gating those two
clauses on the absence of every higher-precedence signal via
_preempts_exec_manual/_preempts_next_action, mirroring _travada_reason's exact
precedence order. blocked-reason:decision/feasibility needed no such guard —
it is already _travada_reason's FIRST check, so nothing can precede it.
story:needs-approval/refino:policy-gap are UNCHANGED and deliberately not
threaded through this guard: they come from a structurally separate lane
(bead_state.py's conveyor for raw/Triagem stories, fetched with an explicit
--status open filter — see painel_visibilidade.py ~L3547-3581), not from
_travada_reason's precedence cascade, so they carry no analogous gap.

CORRECTED (ga-5zug1f, attempt 3/3 FAIL): "so they carry no analogous gap"
above was wrong. Verified against the live source: story:needs-approval IS
status-gated (--status open, single fetch site) and refino:policy-gap
reaches Sua vez only via the open/in_progress/deferred conveyor — but the
predicate checked neither, so a bead carrying either label OUTSIDE that
window still got flagged. Same failure shape as the attempt-2 finding (a
clause firing without checking the reachability condition the real source
actually enforces), same side effect (marker + notify) — just a STATUS
window instead of a LABEL precedence chain. Now threaded through via
_APPROVAL_STATUSES/_POLICY_GAP_STATUSES.

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
# convention — see inflight-reclaim-guard.py's ga-vw26y note). Every bd status
# except "closed" — painel_visibilidade.py's _STATUS_SETTLED is literally
# frozenset({"closed"}), the ONLY terminal status the real panel recognizes.
#
# GATE FIX (ga-5zug1f, 2026-08-15, attempt 3/3 FAIL): this used to list only
# ("open", "in_progress", "deferred", "blocked") — 4 of bd's 7 real statuses
# (`bd statuses`), silently missing "pinned" and "hooked". The story:blocked
# bucket that feeds 🔒 Travadas is fetched with an UNRESTRICTED --all filter
# specifically because status doesn't gate it (painel_visibilidade.py
# ~L2887, verified live), so a hooked- or pinned-status bead carrying
# story:blocked + blocked-reason:decision DOES render in the real panel's
# 👤 Sua vez — but the old allowlist meant scan_rig()'s own
# "bd list --status ..." query could never RETURN that bead in the first
# place, so this guard could never see the gap: not a precedence bug like
# ga-96xden's (the predicate itself was never wrong for that case), a
# narrower one — the ENUMERATION never reached the bead at all, silently
# indistinguishable from "scanned it, found no gap" to every downstream
# consumer. Now every non-"closed" status is fetched, matching painel's own
# single terminal-status invariant exactly instead of re-deriving a subset.
NON_TERMINAL_STATUSES = ("open", "in_progress", "deferred", "blocked", "pinned", "hooked")

# blocked-reason:decision / :feasibility — painel_visibilidade.py's
# _BLOCKED_REASON_ATHOS (line 408).
ATHOS_DECISION_LABELS = frozenset({"blocked-reason:decision", "blocked-reason:feasibility"})

# GATE FIX (ga-5zug1f, attempt 3/3 FAIL): story:needs-approval and
# refino:policy-gap are each reachable in the real panel only within a
# NARROWER status window than the rest of this guard's scan — see the
# is_sua_vez_acao_gap docstring for the verified fetch sites behind each set.
_APPROVAL_STATUSES = frozenset({"open"})
_POLICY_GAP_STATUSES = frozenset({"open", "in_progress", "deferred"})


def _preempts_exec_manual(lset, status):
    """True iff a HIGHER-precedence _travada_reason branch already resolves to
    turn:"other" before the real function would ever reach its exec:manual
    check (painel_visibilidade.py ~L1835-1901) — meaning a bead carrying
    exec:manual, whatever its assignee, is NOT actually routed by turning
    that label; something earlier already won. Self-contained/correct in
    isolation: explicitly excludes the blocked-reason:decision/feasibility
    sub-case (that resolves to turn:"athos", not "other" — handled
    unconditionally by ATHOS_DECISION_LABELS in is_sua_vez_acao_gap, checked
    before this is ever called).
    """
    if (
        "story:blocked" in lset
        or status == "blocked"
        or bool(lset & (ATHOS_DECISION_LABELS
                         | {"blocked-reason:dependency", "blocked-reason:external"}))
        or any(str(l).startswith(("blocked-on:", "blocked:")) for l in lset)
    ) and not (lset & ATHOS_DECISION_LABELS):
        return True
    if lset & {"gate:needs-fix", "gate:failed"}:
        return True
    if "gate:needs-rebase" in lset:
        return True
    if "gate:passed" in lset and "story:in-flight" in lset:
        return True
    if "story:needs-human" in lset or "needs-human" in lset:
        return True
    reclaims = [int(parts[-1]) for l in lset
                if (parts := str(l).split(":"))[0:2] == ["pilot", "reclaim-count"]
                and parts[-1].isdigit()]
    if reclaims and max(reclaims) >= 3:
        return True
    if (any(str(l).startswith("pool:refused") for l in lset)
            or any(str(l).startswith("pilot:refused-reason:") for l in lset)):
        return True
    if "phone-proxy" in lset:
        return True
    return False


def _preempts_next_action(lset, status):
    """True iff a higher-precedence _travada_reason branch beats
    next-action:athos* (painel_visibilidade.py ~L1835-1973). Includes
    exec:manual's own PRESENCE: an owned exec:manual returns turn:"other",
    an orphaned one returns turn:"athos" under the DIFFERENT key
    "exec-manual" — either way _travada_reason has already returned by the
    time it would reach next-action, so a bead's Sua-vez-eligibility here (if
    any) is already fully accounted for by the exec:manual check in
    is_sua_vez_acao_gap, not this one.
    """
    if _preempts_exec_manual(lset, status):
        return True
    if "exec:manual" in lset:
        return True
    if "pilot:no-auto-dispatch" in lset:
        return True
    if ("needs:engine-window" in lset or "framework:engine" in lset
            or any(str(l).startswith("engine-window:") for l in lset)):
        return True
    if "story:awaiting-external-merge" in lset:
        return True
    return False


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


def is_sua_vez_acao_gap(labels, assignee, athos_acao, status=""):
    """True iff this bead renders in painel's 👤 Sua vez AND athos.acao is empty.

    Pure predicate — the reconciled union described in the module docstring.
    Mirrors _travada_reason's turn=="athos" branches (painel_visibilidade.py,
    ~lines 1839-1842 / 1904-1919 / 1965-1968) plus the story:needs-approval /
    refino:policy-gap conveyor-lane check (bead_state.py's ATHOS_TURN).

    `status` (bd issue status, e.g. "open"/"blocked") is required to resolve
    the exec:manual-orphan and next-action:athos* clauses correctly: in the
    real source neither fires if a higher-precedence branch already claimed
    turn:"other" first (see _preempts_exec_manual/_preempts_next_action).

    GATE FIX (ga-5zug1f, attempt 3/3 FAIL): `status` is ALSO required to
    resolve story:needs-approval and refino:policy-gap correctly.
    story:needs-approval is fetched in the real panel EXCLUSIVELY with
    --status open (painel_visibilidade.py ~L3581 — a single, unambiguous
    fetch site, verified no other caller exists). refino:policy-gap reaches
    👤 Sua vez only via the Triagem/story:unrefined conveyor, whose combined
    fetch statuses are open+in_progress (Triagem) union deferred
    (story:unrefined adds it) — never blocked/pinned/hooked. A bead carrying
    either label OUTSIDE its real status window is invisible in the real
    panel, so flagging it here was a false positive with a real side effect
    (marker label + push notification) that never self-clears — see
    _APPROVAL_STATUSES/_POLICY_GAP_STATUSES.

    Defaults to "" (never matches "blocked", nor _APPROVAL_STATUSES /
    _POLICY_GAP_STATUSES) so a caller that omits status only affects
    blocked-reason:decision/feasibility (ATHOS_DECISION_LABELS) — the one
    branch below that is genuinely status-independent in the real source too
    (_travada_reason's unconditional first check).
    """
    if (athos_acao or "").strip():
        return False
    lset = set(labels or [])
    if lset & ATHOS_DECISION_LABELS:
        return True
    if ("exec:manual" in lset and not (assignee or "").strip()
            and not _preempts_exec_manual(lset, status)):
        return True
    if (any(str(l).startswith("next-action:") and "athos" in str(l) for l in lset)
            and not _preempts_next_action(lset, status)):
        return True
    if "story:needs-approval" in lset and status in _APPROVAL_STATUSES:
        return True
    if "refino:policy-gap" in lset and status in _POLICY_GAP_STATUSES:
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
        status = (b.get("status") or "").strip().lower()
        acao = (b.get("metadata") or {}).get("athos.acao")
        has_marker = MARKER_LABEL in labels
        qualifies_gap = is_sua_vez_acao_gap(labels, assignee, acao, status)
        if qualifies_gap and not has_marker:
            gaps.append(bid)
        elif has_marker and not qualifies_gap:
            resolved.append(bid)
    return gaps, resolved


def run_cycle():
    """Scan every rig once; return an explicit result dict.

    ga-ypwdug pre-submission self-audit: an earlier draft returned a plain
    (flagged, resolved) tuple, which was (0, 0) BOTH for "scanned everything,
    genuinely zero gaps" and for "rig enumeration failed outright, scanned
    nothing" — the failure message printed separately, but a log reader
    scanning only the per-cycle summary line could not tell the two apart.
    enumeration_ok / rigs_failed make that distinction part of the return
    value itself, not just a transient print the summary line could outrun.
    """
    rigs = _list_rig_stores()
    if rigs is None:
        print("[ATHOS-ACAO-GUARD] cycle: rig enumeration FAILED — 0 rigs scanned this cycle",
              flush=True)
        return {"flagged": 0, "resolved": 0, "rigs_ok": 0, "rigs_failed": 0,
                "enumeration_ok": False}

    result = {"flagged": 0, "resolved": 0, "rigs_ok": 0, "rigs_failed": 0,
              "enumeration_ok": True}
    for rig_name, rig_path in rigs:
        scan = scan_rig(rig_path)
        if scan is None:
            print(f"[ATHOS-ACAO-GUARD] {rig_name}: query failed, skipping", flush=True)
            result["rigs_failed"] += 1
            continue
        result["rigs_ok"] += 1
        gaps, resolved = scan
        for bid in gaps:
            r = _bd(rig_path, "label", "add", bid, MARKER_LABEL, timeout=15)
            if r.returncode == 0:
                emit(f"[ATHOS-ACAO-GUARD] [FLAGGED] {rig_name}/{bid} missing athos.acao "
                     f"— labeled {MARKER_LABEL}")
                result["flagged"] += 1
            else:
                print(f"[ATHOS-ACAO-GUARD] [FLAG-FAILED] {rig_name}/{bid}: "
                      f"{r.stderr.strip()[:200]}", flush=True)
        for bid in resolved:
            r = _bd(rig_path, "label", "remove", bid, MARKER_LABEL, timeout=15)
            if r.returncode == 0:
                print(f"[ATHOS-ACAO-GUARD] [RESOLVED] {rig_name}/{bid} athos.acao now set "
                      f"— marker removed", flush=True)
                result["resolved"] += 1
            else:
                print(f"[ATHOS-ACAO-GUARD] [RESOLVE-FAILED] {rig_name}/{bid}: "
                      f"{r.stderr.strip()[:200]}", flush=True)
    return result


def _cycle_summary_line(r):
    status = "OK" if (r["enumeration_ok"] and r["rigs_failed"] == 0) else "DEGRADED"
    return (f"[ATHOS-ACAO-GUARD] cycle: flagged={r['flagged']} resolved={r['resolved']} "
            f"rigs_ok={r['rigs_ok']} rigs_failed={r['rigs_failed']} "
            f"enumeration_ok={r['enumeration_ok']} [{status}]")


def main():
    print(f"[ATHOS-ACAO-GUARD] [STARTUP] poll={POLL_SEC}s marker={MARKER_LABEL}", flush=True)
    while True:
        try:
            result = run_cycle()
            print(_cycle_summary_line(result), flush=True)
        except Exception as exc:
            # Never crash the guard loop.
            print(f"[ATHOS-ACAO-GUARD] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


def _selftest():
    """Pure-function regression tests for is_sua_vez_acao_gap(). No bd/gc calls."""
    cases = [
        # (labels, assignee, athos_acao, status, expected, description)
        (["blocked-reason:decision"], "", None, "blocked", True, "blocked-reason:decision, no acao"),
        (["blocked-reason:decision"], "", "algo", "blocked", False, "blocked-reason:decision, acao set"),
        (["blocked-reason:feasibility"], "", "", "blocked", True, "blocked-reason:feasibility, empty-string acao"),
        (["exec:manual"], "", None, "open", True, "exec:manual orphan (wa-jyskd/wa-e8efn/wa-8key3/wa-yyv3j shape)"),
        (["exec:manual"], "oracle-wa", None, "open", False, "exec:manual WITH assignee is not Athos's turn"),
        (["exec:manual"], "", "Nada a decidir", "open", False, "exec:manual orphan, acao already filled"),
        (["next-action:athos-e-oracle"], "", None, "open", True, "next-action:athos* prefix match"),
        (["next-action:oracle-investiga"], "", None, "open", False, "next-action: NOT athos (wa-yyv3j's own label)"),
        (["story:needs-approval"], "", None, "open", True, "story:needs-approval (wa-lzt1z shape)"),
        (["refino:policy-gap"], "", None, "open", True, "refino:policy-gap (bead_state.ATHOS_TURN)"),
        (["ctx:ready", "exec:auto"], "", None, "open", False, "ordinary dispatchable bead, no Athos signal"),
        ([], "", None, "open", False, "no labels at all"),
        (["exec:manual"], "  ", None, "open", True, "whitespace-only assignee counts as unassigned"),
        # ── ga-96xden gate finding (2026-08-15): exec:manual/next-action:athos*
        # are NOT independently sufficient in the real _travada_reason — a
        # higher-precedence branch can preempt either to turn:"other". ──────
        (["exec:manual"], "", None, "blocked", False,
         "gate counter-example: bd status=blocked preempts exec:manual orphan (block wins)"),
        (["exec:manual", "gate:needs-fix"], "", None, "open", False,
         "stale gate:needs-fix preempts exec:manual orphan (gate-fix wins)"),
        (["exec:manual", "gate:failed"], "", None, "open", False,
         "gate:failed preempts exec:manual orphan"),
        (["exec:manual", "gate:needs-rebase"], "", None, "open", False,
         "gate:needs-rebase preempts exec:manual orphan"),
        (["exec:manual", "gate:passed", "story:in-flight"], "", None, "open", False,
         "gate:passed+story:in-flight (gate-passed-unclosed) preempts exec:manual orphan"),
        (["exec:manual", "needs-human"], "", None, "open", False,
         "bare needs-human preempts exec:manual orphan"),
        (["exec:manual", "pool:refused:engine-rebuild-required"], "", None, "open", False,
         "pool:refused:* preempts exec:manual orphan"),
        (["exec:manual", "phone-proxy"], "", None, "open", False,
         "phone-proxy preempts exec:manual orphan"),
        (["exec:manual", "pilot:reclaim-count:3"], "", None, "open", False,
         "reclaim-count AT cap preempts exec:manual orphan"),
        (["exec:manual", "pilot:reclaim-count:2"], "", None, "open", True,
         "reclaim-count BELOW cap does NOT preempt (still a real gap)"),
        (["next-action:athos-decide", "gate:needs-fix"], "", None, "open", False,
         "stale gate:needs-fix preempts next-action:athos*"),
        (["next-action:athos-decide", "pilot:no-auto-dispatch"], "", None, "open", False,
         "pilot:no-auto-dispatch preempts next-action:athos*"),
        (["next-action:athos-decide", "needs:engine-window"], "", None, "open", False,
         "needs:engine-window preempts next-action:athos*"),
        (["next-action:athos-decide", "story:awaiting-external-merge"], "", None, "open", False,
         "story:awaiting-external-merge preempts next-action:athos*"),
        (["next-action:athos-decide", "exec:manual"], "oracle-wa", None, "open", False,
         "exec:manual (even WITH assignee) precedes+preempts next-action:athos* in real source"),
        # ── ga-5zug1f gate finding (2026-08-15, attempt 3/3 FAIL): needs-approval
        # and policy-gap are each reachable in the real panel only within a
        # narrower status window than the rest of this predicate. ──────────────
        (["story:needs-approval"], "", None, "in_progress", False,
         "gate counter-example: story:needs-approval is fetched --status open ONLY "
         "in the real panel — in_progress is invisible there"),
        (["story:needs-approval"], "", None, "blocked", False,
         "story:needs-approval + blocked also outside the real open-only fetch"),
        (["story:needs-approval"], "", None, "", False,
         "story:needs-approval with unknown/omitted status fails closed"),
        (["refino:policy-gap"], "", None, "in_progress", True,
         "refino:policy-gap reachable via Triagem's open+in_progress fetch"),
        (["refino:policy-gap"], "", None, "deferred", True,
         "refino:policy-gap reachable via story:unrefined's +deferred fetch"),
        (["refino:policy-gap"], "", None, "blocked", False,
         "gate counter-example: refino:policy-gap+blocked — the conveyor never "
         "fetches blocked, so this is invisible in the real panel's Sua vez"),
        (["refino:policy-gap"], "", None, "hooked", False,
         "refino:policy-gap+hooked also outside the conveyor's status window"),
        # blocked-reason:decision stays reachable regardless of status (real
        # source's unconditional first check) — guards against a future edit
        # accidentally threading status into ATHOS_DECISION_LABELS too.
        (["blocked-reason:decision"], "", None, "hooked", True,
         "blocked-reason:decision unaffected by ga-5zug1f — still status-independent"),
        (["blocked-reason:decision"], "", None, "pinned", True,
         "blocked-reason:decision unaffected by ga-5zug1f — still status-independent"),
    ]
    assert "pinned" in NON_TERMINAL_STATUSES and "hooked" in NON_TERMINAL_STATUSES, (
        "GATE FIX ga-5zug1f regression: NON_TERMINAL_STATUSES must include every "
        "bd status except closed — pinned/hooked-status beads are live in the "
        "real panel (painel's only terminal status is _STATUS_SETTLED={'closed'})")
    failures = []
    for labels, assignee, acao, status, expected, desc in cases:
        got = is_sua_vez_acao_gap(labels, assignee, acao, status)
        if got != expected:
            failures.append(f"FAIL: {desc} — labels={labels} assignee={assignee!r} "
                             f"acao={acao!r} status={status!r} expected={expected} got={got}")
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
        result = run_cycle()
        print("[ATHOS-ACAO-GUARD] single " + _cycle_summary_line(result)[len("[ATHOS-ACAO-GUARD] "):],
              flush=True)
        _sys.exit(0 if result["enumeration_ok"] else 1)
    main()
