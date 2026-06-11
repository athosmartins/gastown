#!/usr/bin/env python3
"""Supervisor config guard + spawn-outage auto-recovery (ga-h3w2y).

Closes the blind spot behind the ~1h town-wide outage of 2026-06-10: the rig
'deacon' lost its `path` binding in site.toml (forgotten in a city.toml→site.toml
migration). The supervisor then failed `validate rigs: rig "deacon": path is
required` and entered an init-failure RETRY LOOP — so NO sessions spawned
town-wide (gate-reviewers + dogs stuck "start-pending"). The only visible symptom
was a silent spawn-outage; quota / Dolt / bd-hooks were all false trails, and it
took ~1h of hand-digging through supervisor.log to find the real cause.

This daemon is the proactive guard + auto-recovery that outage lacked.

AC#1 — PRE-BOOT GUARD (RunAtLoad=true + every poll):
  Validate that every rig in site.toml has a non-empty `path` AND that the path
  exists on disk. On invalid → notify Athos LOUD with the exact 'rig X sem path'
  and WAKE the Mayor — proactively, BEFORE/while the supervisor silently loops.
  Because the plist sets RunAtLoad, a bad config edit is caught at boot/login
  (and every 60s after), instead of degrading into an unexplained spawn-outage.

AC#2 — SPAWN-OUTAGE AUTO-RECOVERY:
  Detect the supervisor init-failure loop in the recent supervisor.log (the
  spawn-outage signature). Run a diagnostic ladder —
    (a) supervisor init-failure loop?   (b) rig-path config invalid?
    (c) Dolt reachable?                  (d) bd-hooks skew?
  then, ONLY for the known config cause, attempt the canonical fix
  (`gc doctor --fix`) once, re-validate, kickstart the supervisor, and verify.
  WAKE the Mayor with the full ladder result regardless; escalate 🚨 to Athos
  only if unresolved after ESCALATE_AFTER_WAKES cycles.

Philosophy mirrors gate-recovery-watchdog (per Athos, 2026-06-07): a serious
problem must WAKE the Mayor (judgment + recovery playbook) to fix autonomously;
Athos gets an FYI; a 🚨 page is the last resort. The guard never writes config
itself (the correct path for a rig is a human/Mayor decision) — its autonomous
action is bounded to the canonical `gc doctor --fix` plus loud notification.

Never crashes (every external call guarded); silence = healthy.

CLI (for testing / one-shot use):
  --validate [SITE_TOML]   print rig-path problems; exit 0 if clean, 2 if any
  --once                   run a single guard cycle (real actions) then exit
  --dry-run                with --once: print decisions, take NO side effects
"""
import json, time, subprocess, os, re, sys

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
SITE_TOML = os.path.join(CITY, ".gc/site.toml")
SUPERVISOR_LOG = os.environ.get("GC_SUPERVISOR_LOG", "/Users/athos/.gc/supervisor.log")
NOTIFY = "/Users/athos/.local/bin/notify"

POLL_SEC = 60
INIT_FAIL_MIN = 2              # >=2 'init failure #' lines in the recent tail = active loop
TAIL_LINES = 400              # how many recent supervisor.log lines to inspect
WAKE_COOLDOWN_SEC = 1200       # don't re-wake the Mayor more than once per 20min
ESCALATE_AFTER_WAKES = 2       # after 2 unresolved cycles, page Athos 🚨
SUPERVISOR_LABEL = "com.gascity.supervisor"

RIG_HEADER_RE = re.compile(r"^\s*\[\[\s*rig\s*\]\]\s*$")
TABLE_RE = re.compile(r"^\s*\[")
KV_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"')
INIT_FAIL_RE = re.compile(r"init failure #\d+")
VALIDATE_RIGS_RE = re.compile(r"validate rigs:\s*(.+?)(?:\s+see:|\s*\(skipping\)|$)")
BD_HOOK_SKEW_RE = re.compile(r"hook.*(reject|refus|unsupported|incompat)|bead hooks .*(fail|reject)", re.IGNORECASE)


def sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


# ---- AC#1: config validation (zero-dependency site.toml parse; runs on py3.9) ----

def parse_site_rigs(path):
    """Parse [[rig]] tables from site.toml without tomllib (works on any py3).

    Returns a list of dicts: {name, path, has_path}. `has_path` is True only when
    a `path = "..."` key is present in the rig table (even if its value is empty,
    so an empty path is still flagged below)."""
    rigs = []
    cur = None
    with open(path, errors="replace") as f:
        for line in f:
            if RIG_HEADER_RE.match(line):
                if cur is not None:
                    rigs.append(cur)
                cur = {"name": None, "path": None, "has_path": False}
                continue
            if TABLE_RE.match(line):
                # any other [table] / [[table]] ends the current rig block
                if cur is not None:
                    rigs.append(cur)
                cur = None
                continue
            if cur is None:
                continue
            m = KV_RE.match(line)
            if m:
                k, v = m.group(1), m.group(2)
                if k == "name":
                    cur["name"] = v
                elif k == "path":
                    cur["path"] = v
                    cur["has_path"] = True
    if cur is not None:
        rigs.append(cur)
    return rigs


def validate_rigs(site_path=None):
    """Return a list of (rig_name, reason) problems. Empty list = config valid.

    Mirrors the engine's `ValidateRigs` ("path is required") and additionally
    verifies each declared path EXISTS on disk (the story asked for both).
    Resolves SITE_TOML at call-time (not as a default arg) so the daemon can
    point at a fixture in tests and pick up any future global override."""
    site_path = site_path or SITE_TOML
    try:
        rigs = parse_site_rigs(site_path)
    except FileNotFoundError:
        return [("(site.toml)", "site.toml not found at %s" % site_path)]
    except Exception as e:
        return [("(site.toml)", "unreadable: %r" % e)]
    if not rigs:
        return [("(site.toml)", "no [[rig]] entries parsed — file malformed or empty?")]
    problems = []
    for r in rigs:
        name = r.get("name") or "(unnamed rig)"
        p = r.get("path")
        if not r.get("has_path") or not p:
            problems.append((name, "path is required (missing/empty in site.toml)"))
        elif not os.path.isdir(p):
            problems.append((name, "path does not exist on disk: %s" % p))
    return problems


# ---- AC#2: spawn-outage detection + diagnostic ladder ----

def supervisor_init_failure(log_path=None, tail_lines=TAIL_LINES):
    """(looping, validate_error). True when the supervisor is actively cycling
    through init failures in the recent tail of its log. Reads only the last
    ~200KB so it stays cheap on a multi-MB log. Resolves SUPERVISOR_LOG at
    call-time so tests can point at a fixture."""
    log_path = log_path or SUPERVISOR_LOG
    try:
        with open(log_path, errors="replace") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200000))
            lines = f.read().splitlines()[-tail_lines:]
    except Exception:
        return (False, "")
    fails = sum(1 for l in lines if INIT_FAIL_RE.search(l))
    verr = ""
    for l in reversed(lines):
        m = VALIDATE_RIGS_RE.search(l)
        if m:
            verr = m.group(1).strip()
            break
    if fails >= INIT_FAIL_MIN:
        return (True, verr or "init failure loop (validate rigs)")
    return (False, "")


def dolt_reachable():
    r = sh(["gc", "dolt", "status"], timeout=10)
    return bool(r and r.returncode == 0), ("" if (r and r.returncode == 0) else (
        (r.stderr or r.stdout or "").strip()[:200] if r else "timeout/none"))


def bd_hooks_skew(log_path=None):
    """Light grep for the bd/gc hook-skew signature (bd auto-installs lifecycle
    hooks the native store rejects). Returns True if the recent tail shows it."""
    log_path = log_path or SUPERVISOR_LOG
    try:
        with open(log_path, errors="replace") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200000))
            tail = f.read()
    except Exception:
        return False
    return bool(BD_HOOK_SKEW_RE.search(tail))


def diagnostic_ladder():
    """Run the four-rung ladder and return an ordered list of
    (name, tripped:bool, detail:str). The first config rung that trips is the
    likely root cause; later rungs corroborate / rule out false trails."""
    inf, verr = supervisor_init_failure()
    probs = validate_rigs()
    dok, derr = dolt_reachable()
    skew = bd_hooks_skew()
    return [
        ("supervisor_init_failure", inf, verr),
        ("rig_path_invalid", bool(probs), "; ".join("%s: %s" % (n, r) for n, r in probs)),
        ("dolt_unreachable", (not dok), derr),
        ("bd_hooks_skew", skew, ""),
    ]


# ---- actions ----

def notify(msg, prio):
    sh([NOTIFY, "-t", "Supervisor guard", "-p", str(prio), msg], timeout=10)


def mayor_session():
    rs = sh(["gc", "session", "list", "--json"])
    if not rs or rs.returncode != 0:
        return None
    try:
        for s in json.loads(rs.stdout).get("sessions", []):
            if s.get("template") == "gastown.mayor":
                return s.get("id")
    except Exception:
        return None
    return None


def attempt_doctor_fix():
    """Run the canonical `gc doctor --fix` once. Returns (ran:bool, output:str).
    Bounded — doctor can touch several checks, so we run it at most once per
    outage cycle (guarded by the wake cooldown in the caller)."""
    r = sh(["gc", "doctor", "--fix"], timeout=120)
    if not r:
        return (False, "(gc doctor --fix timed out / failed to launch)")
    return (True, ((r.stdout or "") + (r.stderr or "")).strip()[-1500:])


def kickstart_supervisor():
    uid = str(os.getuid())
    return sh(["launchctl", "kickstart", "-k", "gui/%s/%s" % (uid, SUPERVISOR_LABEL)], timeout=20)


def ladder_text(ladder):
    return "\n".join(
        "  [%s] %s%s" % ("TRIPPED" if t else "  ok   ", n, (" — " + d) if d else "")
        for n, t, d in ladder
    )


def wake_mayor(reason, ladder, fix_output=None):
    mid = mayor_session()
    if not mid:
        return False
    fix_block = ""
    if fix_output is not None:
        fix_block = (
            "\n\nJÁ TENTEI o conserto canônico `gc doctor --fix` (1x). Saída (cauda):\n%s\n"
            % fix_output
        )
    task = (
        "🔧 ALERTA AUTOMÁTICO — supervisor-config-guard. Conserta agora; só escale pro Athos se falhar.\n\n"
        "Detectei uma ameaça de SPAWN-OUTAGE town-wide (causa do incidente ga-h3w2y de 2026-06-10): "
        "%s\n\n"
        "Ladder de diagnóstico:\n%s%s\n\n"
        "CAUSA #1 conhecida: um rig sem `path` no site.toml (esquecido numa migração city.toml→site.toml) "
        "faz o supervisor falhar `validate rigs: rig \"X\": path is required` e entrar em LOOP de init-failure "
        "→ NADA spawna town-wide (reviewers+dogs start-pending). Memória: o caçar isso à mão custou ~1h.\n\n"
        "CONSERTO (verificando entre os passos):\n"
        "1. Confirme o rig culpado: `gc doctor --json | jq '.checks[] | select(.name==\"config-valid\")'` "
        "ou `grep 'validate rigs' ~/.gc/supervisor.log | tail`.\n"
        "2. Restaure o `path` do rig em %s — `[[rig]]` precisa de `name=` E `path=\"/Users/athos/gt/<rig>\"` "
        "(o path TEM que existir no disco). NÃO invente o path; use o diretório canônico do rig.\n"
        "3. Re-valide: `gc doctor` (check config-valid deve ficar verde) e dispare o supervisor de novo: "
        "`launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor`.\n"
        "4. Confirme recuperação: as sessões voltam a spawnar (gate-reviewers/dogs saem de start-pending). "
        "Se o init-failure persistir com config VÁLIDO, suba a causa não-config do ladder (Dolt / bd-hooks).\n"
    ) % (reason, ladder_text(ladder), fix_block, SITE_TOML)
    sh(["gc", "session", "wake", mid], timeout=20)
    r = sh(["gc", "session", "nudge", mid, task], timeout=25)
    return r is not None and r.returncode == 0


# ---- guard cycle ----

def run_cycle(dry_run=False):
    """One guard pass. Returns (problem:bool, reason:str, ladder, fixed:bool).

    A problem is raised when EITHER the proactive config validation fails (AC#1)
    OR the supervisor is actively looping on init-failure (AC#2). For the known
    config cause we attempt the canonical fix once (unless dry-run)."""
    probs = validate_rigs()
    inf, verr = supervisor_init_failure()
    config_bad = bool(probs)
    problem = config_bad or inf
    if not problem:
        return (False, "", [], False)

    if config_bad:
        reason = "config inválido em site.toml — " + "; ".join("%s: %s" % (n, r) for n, r in probs)
    else:
        reason = "supervisor em loop de init-failure — " + (verr or "validate rigs")

    ladder = diagnostic_ladder()
    fixed = False
    fix_output = None

    # Autonomous fix is bounded to the canonical path AND only when the config is
    # the confirmed cause (never blind-fix on a non-config init failure).
    if config_bad and not dry_run:
        ran, fix_output = attempt_doctor_fix()
        if ran and not validate_rigs():
            fixed = True
            kickstart_supervisor()
    elif config_bad and dry_run:
        fix_output = "(dry-run: would run `gc doctor --fix`)"

    return (problem, reason, ladder, fixed, fix_output)


def main():
    last_wake = 0
    wakes_since_recovery = 0
    print("[config-guard] supervisor config guard started — validates site.toml rig paths "
          "(AC#1) + auto-recovers spawn-outage (AC#2); silence = healthy", flush=True)
    while True:
        try:
            problem, reason, ladder, fixed, fix_output = run_cycle()
            if not problem:
                if wakes_since_recovery > 0:
                    print("[config-guard] recovered (config valid, no init-failure loop) — resetting", flush=True)
                    notify("Supervisor recuperou — config válido e spawn voltou ao normal.", 3)
                    wakes_since_recovery = 0
            elif fixed:
                print("[config-guard] auto-fixed config via `gc doctor --fix` + kickstarted supervisor: %s" % reason, flush=True)
                notify("Config do supervisor consertado automaticamente (gc doctor --fix) + supervisor reiniciado. "
                       "Você não precisa agir.", 3)
                wakes_since_recovery = 0
                last_wake = time.time()
            elif time.time() - last_wake > WAKE_COOLDOWN_SEC:
                woke = wake_mayor(reason, ladder, fix_output)
                last_wake = time.time()
                wakes_since_recovery += 1
                if wakes_since_recovery >= ESCALATE_AFTER_WAKES:
                    notify("🚨 SUPERVISOR/SPAWN ainda quebrado após o Mayor tentar (%dx): %s. Precisa de você."
                           % (wakes_since_recovery, reason), 5)
                    print("[config-guard] ESCALATED to Athos (%d wakes): %s" % (wakes_since_recovery, reason), flush=True)
                else:
                    notify("Risco de spawn-outage (%s) — Mayor acordado pra consertar. Você não precisa agir." % reason, 4)
                    print("[config-guard] woke Mayor (woke=%s): %s" % (woke, reason), flush=True)
        except Exception as e:
            print("[config-guard] loop error (continuing): %r" % e, flush=True)
        time.sleep(POLL_SEC)


def _cli():
    args = sys.argv[1:]
    if "--validate" in args:
        i = args.index("--validate")
        path = args[i + 1] if i + 1 < len(args) and not args[i + 1].startswith("--") else SITE_TOML
        problems = validate_rigs(path)
        if not problems:
            print("OK: all rigs in %s have a valid, existing path" % path)
            return 0
        print("INVALID config in %s:" % path)
        for name, reason in problems:
            print("  - rig %s: %s" % (name, reason))
        return 2
    if "--once" in args:
        dry = "--dry-run" in args
        res = run_cycle(dry_run=dry)
        problem, reason = res[0], res[1]
        if not problem:
            print("OK: no config problem and no init-failure loop")
            return 0
        ladder, fixed, fix_output = res[2], res[3], res[4]
        print("PROBLEM: %s" % reason)
        print("ladder:\n%s" % ladder_text(ladder))
        print("fixed:", fixed)
        if fix_output:
            print("fix_output:\n%s" % fix_output)
        return 0
    main()
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
