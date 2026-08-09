#!/usr/bin/env python3
"""escalate_emergency.py (ga-aw2ga) — the single canonical path that pages the
human (Athos) with a guaranteed 🚨 push, gated to exactly 3 emergency classes.

Layer 4 of the autonomous escalation ladder (ga-qw3p epic): Layer 1 topic-routes
a stuck bead (escalation-router.sh), Layer 2 escalates it to the Mayor after
30min (agent-stuck-escalation.sh), Layer 3 convenes a 2-of-3 crew quorum
(quorum-convergence-watchdog.py). This is Layer 4 — the last resort that
actually wakes Athos. It is deliberately narrow: everything that reaches this
module pages the phone; everything else stays autonomous or lands in the
digest at most (mol-digest-generate) — even if it already reached the Mayor.

THE 3 SANCTIONED CLASSES (bead ga-aw2ga, story.criterios — do not add a 4th
without updating this docstring and the bead):
  data-security   — data loss, leaked credential, Dolt corruption/integrity
  town-halted     — gate down, Dolt down, pipeline 100% stuck (self-heal exhausted)
  quorum-diverged — ga-yesdn's 2-of-3 crew quorum failed to reach a majority

WHY A NEW FUNCTION AND NOT JUST `notify -p 5 -t '🚨 ...'` DIRECTLY: notify's own
routing (classify_route_detail(), wa-fia0 — deliberately out of scope here per
this bead's own story.dependencias) decides push-vs-digest from MESSAGE
CONTENT, not priority or emoji — notify's own comment: "Prioridade e 🚨 no
título NÃO forçam mais push sozinhos". Measured directly against the live
quorum-diverged message text before this module existed: a 3-way vote split or
a zero-vote timeout matched none of notify's push rules and silently fell to
the muted digest topic despite `-p 5` plus a 🚨 title — contradicting this
bead's own acceptance criterion that a diverged quorum ALWAYS pages.
NOTIFY_FORCE_PUSH=1 is notify's own documented escape hatch for a caller that
already knows the message must reach the phone — this module sets it so
delivery never depends on message wording, without touching the general
classifier (wa-fia0) at all.

SAFETY:
  - Rejects any class not in VALID_CLASSES — a hard failure, not a silent
    no-op. This is what keeps the path "único": a caller cannot invent a 4th
    reason to page the human through this module without editing it (and this
    docstring) first.
  - DRY_RUN=1 (env) or dry_run=True (param) → log the intended escalation to
    the ledger, call neither notify nor mail.
  - mail_mayor=True by default: a durable record alongside the push (a push
    can be missed or dismissed; the mail bead cannot). Best-effort, never
    blocks or fails the notify call.
  - Every call — including dry-run — is appended to the escalate-emergency
    ledger, so a future "are we spamming or under-firing 🚨?" audit has real
    per-class counts instead of guesswork.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gc_ledger import gc_ledger_append as _ledger_append

NOTIFY = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC = os.environ.get("GC_BIN", "gc")
NOTIFY_TIMEOUT = int(os.environ.get("ESCALATE_NOTIFY_TIMEOUT", "10"))
MAIL_TIMEOUT = int(os.environ.get("ESCALATE_MAIL_TIMEOUT", "20"))

# The 3 sanctioned classes (ga-aw2ga). Keys are the stable identifiers callers
# pass in; values are the human-readable label used in the notify title / mail
# subject. Adding a key here without updating story.criterios on ga-aw2ga (or
# its successor) defeats the entire point of this module.
CLASS_LABELS: dict[str, str] = {
    "data-security": "Risco de dado/segurança",
    "town-halted": "Town parado",
    "quorum-diverged": "Quórum divergiu",
}
VALID_CLASSES = frozenset(CLASS_LABELS)


class InvalidEmergencyClass(ValueError):
    """Raised when escalate_emergency() is called with a class outside the 3 sanctioned ones."""


def _is_dry_run(explicit: bool | None) -> bool:
    if explicit is not None:
        return explicit
    return os.environ.get("ESCALATE_DRY_RUN", "0") == "1"


def escalate_emergency(
    emergency_class: str,
    title: str,
    message: str,
    *,
    mail_mayor: bool = True,
    dry_run: bool | None = None,
) -> bool:
    """Page Athos with a guaranteed 🚨 push.

    Returns True once the escalation has run (a dry run counts as run).
    Raises InvalidEmergencyClass if emergency_class is not one of the 3
    sanctioned classes — callers must not catch this and substitute a
    "close enough" class; fix the call site to use a real one, or escalate
    the case for a 4th class to be added deliberately.
    """
    if emergency_class not in VALID_CLASSES:
        raise InvalidEmergencyClass(
            f"{emergency_class!r} is not a sanctioned emergency class "
            f"(must be one of {sorted(VALID_CLASSES)}) — see ga-aw2ga story.criterios"
        )

    label = CLASS_LABELS[emergency_class]
    notify_title = f"🚨 {label}: {title}"
    mail_subject = f"🚨 {label}: {title}"
    is_dry = _is_dry_run(dry_run)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    _ledger_append(
        "escalate-emergency",
        {"ts": ts, "class": emergency_class, "title": title, "dry_run": is_dry},
        fail_open=True,
    )

    if is_dry:
        print(f"[ESCALATE] [DRY_RUN] class={emergency_class} title={title!r}", flush=True)
        return True

    # notify_ok tracks whether the push subprocess actually exited 0 — NOT
    # end-to-end delivery certainty (that's only knowable from notify's own
    # history.db), but distinct from "we don't know", which a bare
    # try/except-and-forget would silently collapse into "succeeded".
    notify_ok = False
    try:
        env = dict(os.environ)
        env["NOTIFY_FORCE_PUSH"] = "1"
        result = subprocess.run(
            [NOTIFY, "-t", notify_title, "-p", "5", message],
            capture_output=True, text=True, timeout=NOTIFY_TIMEOUT, env=env,
        )
        notify_ok = result.returncode == 0
        if not notify_ok:
            print(f"[ESCALATE] [WARN] notify exited {result.returncode}: {result.stderr.strip()}",
                  file=sys.stderr, flush=True)
    except Exception as exc:
        print(f"[ESCALATE] [ERROR] notify failed: {exc}", file=sys.stderr, flush=True)

    if mail_mayor:
        try:
            subprocess.run(
                [GC, "mail", "send", "mayor", "-s", mail_subject, "-m", message],
                capture_output=True, text=True, timeout=MAIL_TIMEOUT,
            )
        except Exception as exc:
            print(f"[ESCALATE] [WARN] mail mayor failed: {exc}", file=sys.stderr, flush=True)

    print(f"[ESCALATE] class={emergency_class} title={title!r} notify_ok={notify_ok}", flush=True)
    return notify_ok


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="escalate_emergency.py",
        description=(
            "Page Athos with a guaranteed 🚨 push — restricted to the 3 "
            "sanctioned emergency classes (ga-aw2ga: data-security, "
            "town-halted, quorum-diverged)."
        ),
    )
    p.add_argument("--class", dest="emergency_class", required=True,
                    choices=sorted(VALID_CLASSES),
                    help="which of the 3 sanctioned classes this escalation belongs to")
    p.add_argument("--title", required=True,
                    help="short title (goes in the notify title / mail subject)")
    p.add_argument("--no-mail", action="store_true",
                    help="skip mailing mayor (rare; default is to also mail)")
    p.add_argument("message", nargs="*", help="message body (or piped via stdin)")
    args = p.parse_args(argv)

    if args.message:
        message = " ".join(args.message)
    elif not sys.stdin.isatty():
        message = sys.stdin.read().strip()
    else:
        p.error("provide a message as an argument or via stdin")

    if not message:
        p.error("message cannot be empty")

    try:
        escalate_emergency(args.emergency_class, args.title, message, mail_mayor=not args.no_mail)
    except InvalidEmergencyClass as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


# ── standalone / selftest entry point ─────────────────────────────────────────
def _selftest() -> int:
    from unittest import mock

    this_module = sys.modules[__name__]
    PASS = 0
    FAIL = 0

    def ok(msg: str) -> None:
        nonlocal PASS
        PASS += 1
        print(f"  PASS: {msg}")

    def bad(msg: str) -> None:
        nonlocal FAIL
        FAIL += 1
        print(f"  FAIL: {msg}")

    print("=== escalate_emergency.py --selftest ===")

    # T1: valid class → notify invoked with NOTIFY_FORCE_PUSH=1 + -p 5 — the
    # actual fix this module exists to deliver, not just "notify was called".
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append") as m_ledger:
        escalate_emergency("quorum-diverged", "T1 title", "T1 body", mail_mayor=False)
        cmd, kwargs = m_run.call_args.args[0], m_run.call_args.kwargs
        if cmd[0] == NOTIFY and "-p" in cmd and cmd[cmd.index("-p") + 1] == "5":
            ok("T1a: notify invoked with -p 5")
        else:
            bad(f"T1a: unexpected notify command: {cmd}")
        env = kwargs.get("env") or {}
        if env.get("NOTIFY_FORCE_PUSH") == "1":
            ok("T1b: NOTIFY_FORCE_PUSH=1 set (guarantees delivery, bypasses content classifier)")
        else:
            bad(f"T1b: NOTIFY_FORCE_PUSH missing/wrong: {env.get('NOTIFY_FORCE_PUSH')!r}")
        if m_ledger.call_count == 1:
            ok("T1c: ledger append called exactly once")
        else:
            bad(f"T1c: expected 1 ledger append, got {m_ledger.call_count}")

    # T2: an unsanctioned class is REJECTED and notify is never reached —
    # mutation check that the guard actually blocks, not merely that valid
    # input happens to pass (a guard that never fires proves nothing).
    with mock.patch.object(subprocess, "run") as m_run:
        try:
            escalate_emergency("gate-review-nitpick", "T2", "body")
            bad("T2a: expected InvalidEmergencyClass for an unsanctioned class")
        except InvalidEmergencyClass:
            ok("T2a: unsanctioned class raises InvalidEmergencyClass")
        if m_run.call_count == 0:
            ok("T2b: notify NOT called for a rejected class")
        else:
            bad(f"T2b: notify was called {m_run.call_count}x despite an invalid class")

    # T3: dry_run=True logs but calls neither notify nor mail.
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append") as m_ledger:
        escalate_emergency("town-halted", "T3", "body", dry_run=True)
        if m_run.call_count == 0:
            ok("T3a: dry_run=True calls no subprocess (notify/mail)")
        else:
            bad(f"T3a: dry_run=True still invoked subprocess {m_run.call_count}x")
        if m_ledger.call_count == 1:
            ok("T3b: dry_run=True still logs to the ledger (audit trail preserved)")
        else:
            bad(f"T3b: expected 1 ledger call in dry run, got {m_ledger.call_count}")

    # T4: mail_mayor=False still notifies but skips mailing mayor.
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append"):
        escalate_emergency("data-security", "T4", "body", mail_mayor=False)
        calls = [c.args[0][0] for c in m_run.call_args_list]
        if calls == [NOTIFY]:
            ok("T4: mail_mayor=False notifies but skips mailing mayor")
        else:
            bad(f"T4: unexpected call set with mail_mayor=False: {calls}")

    # T5: default mail_mayor=True calls both notify and gc mail send mayor.
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append"):
        escalate_emergency("data-security", "T5", "body")
        calls = [c.args[0][0] for c in m_run.call_args_list]
        if calls == [NOTIFY, GC]:
            ok("T5: default mail_mayor=True calls both notify and gc mail send mayor")
        else:
            bad(f"T5: expected [notify, gc], got: {calls}")

    # T6: all 3 sanctioned classes force-push (not just the one T1 exercised).
    for cls in sorted(VALID_CLASSES):
        with mock.patch.object(subprocess, "run") as m_run, \
             mock.patch.object(this_module, "_ledger_append"):
            escalate_emergency(cls, f"T6-{cls}", "body", mail_mayor=False)
            env = m_run.call_args.kwargs.get("env") or {}
            if env.get("NOTIFY_FORCE_PUSH") == "1":
                ok(f"T6: class {cls!r} force-pushes")
            else:
                bad(f"T6: class {cls!r} did NOT set NOTIFY_FORCE_PUSH")

    # T7: CLI rejects an invalid --class before ever reaching escalate_emergency
    # (defense in depth at the argparse layer, via choices=).
    try:
        main(["--class", "bogus", "--title", "x", "body"])
        bad("T7: main() should exit nonzero for an invalid --class")
    except SystemExit as exc:
        if exc.code and exc.code != 0:
            ok("T7: CLI rejects an invalid --class (argparse choices=)")
        else:
            bad(f"T7: main() exited with code {exc.code}, expected nonzero")

    # T8: CLI happy path — joins positional message args, exits 0, notifies once.
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append"):
        rc = main(["--class", "quorum-diverged", "--title", "T8", "--no-mail", "hello", "world"])
        if rc == 0 and m_run.call_count == 1:
            ok("T8a: CLI happy path exits 0 and invokes notify once")
        else:
            bad(f"T8a: rc={rc} call_count={m_run.call_count}")
        sent_msg = m_run.call_args.args[0][-1]
        if sent_msg == "hello world":
            ok("T8b: CLI joins positional message args with spaces")
        else:
            bad(f"T8b: expected joined message 'hello world', got {sent_msg!r}")

    # T9: return value reflects the ACTUAL notify exit code — not a blanket
    # True regardless of outcome (the third-state bug: "couldn't confirm" and
    # "confirmed it worked" must not collapse to the same return value).
    with mock.patch.object(subprocess, "run") as m_run, \
         mock.patch.object(this_module, "_ledger_append"):
        m_run.return_value = subprocess.CompletedProcess([], returncode=0)
        result_ok = escalate_emergency("town-halted", "T9-ok", "body", mail_mayor=False)
        if result_ok is True:
            ok("T9a: notify returncode=0 -> escalate_emergency returns True")
        else:
            bad(f"T9a: expected True, got {result_ok!r}")

        m_run.return_value = subprocess.CompletedProcess([], returncode=1, stderr="boom")
        result_fail = escalate_emergency("town-halted", "T9-fail", "body", mail_mayor=False)
        if result_fail is False:
            ok("T9b: notify returncode=1 -> escalate_emergency returns False (not silently True)")
        else:
            bad(f"T9b: expected False, got {result_fail!r}")

    print(f"\n=== RESULT: PASS={PASS} FAIL={FAIL} ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(_selftest())
    sys.exit(main())
