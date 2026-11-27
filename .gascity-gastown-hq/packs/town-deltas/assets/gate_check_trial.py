"""gate_check_trial.py — ga-mw5gdyu.3 (auto-melhoria, fatia 3): the A/B ruler of a mechanical check IN TRIAL (registry status `em-teste`). A check built from a .2 bead imports this instead of copying third-state-reads-check.py's
conf/arm/record code, so every check in trial splits and records the same way and scripts/gate-checks-ratchet.py can read them all. Protected like the meter: the bead that asks for a check forbids editing it and the gate reviews any edit; this slice has no mechanical lock.

CONTRACT (docs/runbooks/gate-checks-ratchet.md), for a check script <dir>/<stem>-check.py (the registry's `check` column STARTS with that path):
  conf   <state>/<stem>.conf        mode=enforce|warn|off and enforce_pct=1..100, the grammar of third-state-reads.conf. The RATCHET writes it (entry: enforce 50; promoted: enforce 100; off) with its own record in a `# ratchet {json}` comment line; the check only reads it (`resolve`).
  arm    SHA-256("<stem>:<bead>") first 8 hex, mod 100 < enforce_pct → "enforce", else "holdout" (the same draw as third-state-reads-check.py with salt = stem: a pure function of the bead, so a resubmitted bead never changes arm).
         `holdout` runs the SAME check as warn: it records what it would have refused and refuses nothing.
  runs   <state>/<stem>-runs.jsonl  one JSON line per run the check records (`record_run`, EVERY run with a bead, also a clean one):
         {bead, ts (UTC, AAAA-MM-DDTHH:MM:SSZ), arm, verdict ok|achados|nao-sei, pontos [cited points], dispensados [points the author waived]}.
         A point is any text that stays the same for the same finding across runs (e.g. "<path>#<sha256 of the line without its whitespace>": a reflow keeps it, an edit changes it). `achados` needs at least one point.
Three states everywhere: conf absent = "not switched on" (checks nothing); conf unreadable or invalid = NÃO SEI (never "off", never "on"); a run that could not be recorded is said (`record_run` returns why), never dropped quietly."""
import contextlib
import hashlib
import json
import os
import re
import time

MODES = ("enforce", "warn", "off")
ARMS = ("enforce", "holdout")
VERDICTS = ("ok", "achados", "nao-sei")
TRIAL_PCT = 50
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"
CHECK_RE = re.compile(r"^([a-z0-9][a-z0-9_-]*)-check\.py$")


def stem_of(cell):
    """-> (stem, rel, why) from the registry's `check` cell: its first token must be a repo-relative path ending in <stem>-check.py. (None, None, why) otherwise: the cell is data from a delivery, so the path must be repo-relative (no `..`, not absolute)."""
    # vazio → (None, None, why): a blank cell names no check; falhou/ilegível → n/a (a pure string parse)
    tok = (str(cell).split() or [""])[0]
    parts = tok.split("/")
    m = CHECK_RE.match(parts[-1])
    if any(p in ("", ".", "..") for p in parts) or not m:
        return None, None, "a coluna check deve começar pelo caminho <dir>/<nome>-check.py, relativo e sem `..` (veio %r)" % tok[:80]
    return m.group(1), tok, ""


def conf_path(state, stem):
    return os.path.join(state, stem + ".conf")


def runs_path(state, stem):
    return os.path.join(state, stem + "-runs.jsonl")


def read_conf(state, stem):
    """-> (st, mode, pct, notes): st = absent | ok | unreadable | invalid:<why> (the grammar of third-state-reads-check.py's load_conf, which the test holds equal), and the text of every full-line comment, all from ONE read of the file (the ratchet keeps its record in a comment)."""
    # vazio → arquivo vazio/só comentários = invalid:no-keys (é o que um write falho deixa; não liga nada em silêncio); falhou/ilegível → unreadable/invalid, nunca "absent"
    path = conf_path(state, stem)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return ("unreadable" if os.path.islink(path) else "absent"), None, None, []
    except (OSError, ValueError):
        return "unreadable", None, None, []
    notes = [x.strip()[1:].strip() for x in text.splitlines() if x.strip().startswith("#")]
    mode, pct, seen = "enforce", 100, 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        k, _, v = (x.strip() for x in line.partition("="))
        seen += 1
        if k == "mode" and v in MODES:
            mode = v
        elif k == "enforce_pct" and re.fullmatch(r"[0-9]{1,3}", v) and 1 <= int(v) <= 100:
            pct = int(v)
        else:
            return "invalid:" + line, None, None, notes
    return ("ok", mode, pct, notes) if seen else ("invalid:no-keys", None, None, notes)


def load_conf(state, stem):
    """-> (st, mode, pct): read_conf without the comments."""
    return read_conf(state, stem)[:3]


def write_conf(state, stem, mode, pct=None, note=""):
    """-> "" when <state>/<stem>.conf now holds exactly this (enforce needs pct 1..100; `note` = one comment line), else why and nothing changed. Atomic: a temp file in the same directory, then rename."""
    # vazio → n/a (a write); falhou → the OSError text, with the temp file removed: the caller must not read "" as done
    if mode not in MODES:
        return "modo %r fora de %s" % (mode, "|".join(MODES))
    if mode == "enforce" and not (type(pct) is int and 1 <= pct <= 100):
        return "enforce_pct %r fora de 1..100" % (pct,)
    if "\n" in note:
        return "a nota da conf deve ser UMA linha"
    path = conf_path(state, stem)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("mode=%s\n" % mode + ("enforce_pct=%d\n" % pct if mode == "enforce" else "") + ("# %s\n" % note if note else ""))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as e:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        return "não consegui gravar %s: %s" % (path, e.strerror or e)
    return ""


def arm_for(stem, bead, pct):
    return "enforce" if int(hashlib.sha256((stem + ":" + bead).encode()).hexdigest()[:8], 16) % 100 < pct else "holdout"


def resolve(state, stem, bead):
    """-> (st, eff, arm, why): what a check does for this bead. st desligado (conf absent or mode=off: check nothing) | ok | nao-sei (conf unreadable/invalid, or enforce_pct<100 with no bead to draw the arm).
    eff = "enforce" (a finding refuses) | "warn" (records, refuses nothing: mode warn, or the holdout arm); arm = "enforce" | "holdout" | "-" (no draw). Only st == "ok" comes without a why."""
    st, mode, pct = load_conf(state, stem)
    if st == "absent":
        return "desligado", None, "-", "sem %s: a checagem não foi ligada" % os.path.basename(conf_path(state, stem))
    if st != "ok":
        return "nao-sei", None, "-", "%s está %s" % (os.path.basename(conf_path(state, stem)), st)
    if mode == "off":
        return "desligado", None, "-", "mode=off"
    if mode == "warn":
        return "ok", "warn", "-", ""
    if not bead:
        return ("ok", "enforce", "enforce", "") if pct == 100 else ("nao-sei", None, "-", "enforce_pct=%d precisa da bead para sortear o braço" % pct)
    arm = arm_for(stem, bead, pct)
    return "ok", "warn" if arm == "holdout" else "enforce", arm, ""


def row_ok(d):
    """-> "" when d is a run row of the contract (pontos/dispensados may be absent = []), else why. The reader (the ratchet) and the writer (record_run) judge by this one function."""
    if not isinstance(d, dict):
        return "a linha não é um objeto"
    if not (isinstance(d.get("bead"), str) and d["bead"].strip()):
        return "bead ausente ou vazia"
    try:
        time.strptime(d.get("ts"), TS_FMT)
    except (TypeError, ValueError):
        return "ts %r não é AAAA-MM-DDTHH:MM:SSZ" % (d.get("ts"),)
    if d.get("arm") not in ARMS or d.get("verdict") not in VERDICTS:
        return "arm %r ou verdict %r fora de %s / %s" % (d.get("arm"), d.get("verdict"), "|".join(ARMS), "|".join(VERDICTS))
    for k in ("pontos", "dispensados"):
        v = d.get(k, [])
        if not (isinstance(v, list) and all(isinstance(x, str) and x for x in v)):
            return "%s deve ser uma lista de textos não vazios" % k
    return "achados sem nenhum ponto citado" if d["verdict"] == "achados" and not d.get("pontos") else ""


def record_run(state, stem, bead, arm, verdict, pontos=(), dispensados=(), ts=None):
    """-> "" when ONE line was appended to <state>/<stem>-runs.jsonl, else why (nothing written). A row row_ok would reject is not written: the reader would count it as damage and the ratchet would hold the whole trial."""
    # vazio → n/a (a write); falhou/ilegível → the OSError text (a line torn by a crash is damage the ratchet reports: NÃO SEI, not silence)
    row = {"bead": bead, "ts": ts or time.strftime(TS_FMT, time.gmtime()), "arm": arm, "verdict": verdict,
           "pontos": list(pontos) if isinstance(pontos, (list, tuple)) else pontos, "dispensados": list(dispensados) if isinstance(dispensados, (list, tuple)) else dispensados}
    why = row_ok(row)
    if why:
        return "linha recusada: " + why
    path = runs_path(state, stem)
    data = (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as e:
        return "não consegui gravar %s: %s" % (path, e.strerror or e)
    return ""

