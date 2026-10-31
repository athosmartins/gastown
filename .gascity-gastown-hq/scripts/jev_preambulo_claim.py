#!/usr/bin/env python3
"""jev_preambulo_claim.py (ga-aijm2v.13) — the CLAIM-TIME half of "preambulo por tarefa" (path (b), Mayor 26/09).

WHAT IT IS
  `gc prime` renders the same doctrine for every session of a pool and cannot see the task (it does not even know
  the session: only the pool slot, see docs/pool-preamble-per-task.md). So the optional sections the manifest lists
  under `doctrine.per_task.eligible` are loaded HERE instead: right after a session claims a bead it runs

      python3 $GC_CITY_PATH/scripts/jev_preambulo_claim.py --bead <id> --role <TD_ROLE> --arm experiment

  and this prints the text of the eligible sections Jev did NOT dispense for that task. Nothing is written to a
  shared file, nothing is built or swapped: it is a reader that prints to the session's own stdout.

  It is INERT until something calls it: no order, hook or prompt line runs it today (that wiring is its own slice,
  see the bead). It reuses the shadow's decision code unchanged (`jev_preambulo_experiment.process_entity` ->
  `decide_sections`): same questions, same threshold, same structural floors, same injection markers. What is new
  is only that the answer is PRINTED and logged as a live record (mode "preambulo_vivo", never "preambulo": the
  shadow report, `load_done` and the daily suppression report all key on the shadow's mode and keep not seeing it).

THE THIRD STATE IS "PRINT IT" (fail-open, the acceptance criterion "Jev out/slow/error => full doctrine")
  A section is withheld ONLY when Jev answered THAT section's question with P(needed) < threshold and no floor or
  injection marker says keep. Everything else is printed, each with its reason in the log:
    - Jev unavailable / slow / error / malformed answer  -> that section (or all of them) printed;
    - the whole decision exceeds DEADLINE_S                -> ALL eligible sections printed ("tempo_esgotado");
    - the bead cannot be read                              -> ALL eligible sections printed ("bead_ilegivel");
    - an unexpected exception                              -> ALL eligible sections printed ("erro_inesperado").
  If even the policy cannot be loaded the loader cannot know what the prime withheld: it prints a notice that says
  so and names the fragment file to read in full, and exits 3 (never an empty stdout that reads like "nothing to load").

ARMS
  --arm is REQUIRED and is the arm of the SESSION (decided at prime by pool slot, not here): the control arm keeps the
  whole doctrine at prime, so it prints one line saying that and does nothing else (no Jev call, no record). The
  shadow's per-bead hash arm is kept in the record as `arm_hash` — it is a different assignment and must not be
  confused with the live one.

--all  prints every eligible section without asking Jev (the way out when a task turns into something a withheld
  section covers, mid-task). It is logged: a session that had to ask for a withheld section is the strongest
  evidence that the cut was wrong ("any failure attributed to a cut section makes that section core").
--dry-run  decides and prints, writes no record (manual checks must not pollute the live log).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402
import jev_gate_verdict_experiment as gv  # noqa: E402
import jev_preambulo_experiment as pe  # noqa: E402

MODE_VIVO = "preambulo_vivo"
FASE_VIVO = "vivo"
ARMS = ("experiment", "control")
DEADLINE_S = float(os.environ.get("JEV_PREAMBULO_CLAIM_DEADLINE_S", "25"))  # whole decision: bead read + Jev call
EXIT_NO_POLICY = 3


# ── the sections' text ─────────────────────────────────────────────────────────────────
def section_texts(policy: dict) -> dict[str, str]:
    """section id -> the text the prime would have rendered for it (no template action lives inside an eligible
    section: `pool-preamble-build.py check` pins that role_text() is byte-equal to the real render). Raises
    pe.PolicyError when the fragment cannot be parsed. Reads the fragment once; a section that does not exist
    simply has no entry (the caller treats a missing text as a failure to print, not as an empty section)."""
    ppb = policy["ppb"]
    # Fragment read. vazio -> parse_fragment raises (no `define` line), so an empty file is a failure, not "no sections";
    # falhou/ilegível -> PolicyError, which the caller turns into the "NÃO CARREGADA" notice.
    try:
        blocks = ppb.parse_fragment(ppb.FRAGMENT.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise pe.PolicyError(f"cannot read the fragment {ppb.FRAGMENT}: {type(e).__name__}: {e}") from e
    return {b["id"]: "\n".join(b["lines"]).rstrip("\n") for b in blocks}


def fragment_path(policy: dict | None = None) -> Path:
    """Where a session reads the doctrine by hand when the loader itself is down."""
    if policy is not None:
        return Path(policy["ppb"].FRAGMENT)
    return pe._assets_dir().parent / "template-fragments" / "town-deltas.template.md"


# ── rendering ──────────────────────────────────────────────────────────────────────────
def render(bead_id: str, role: str, arm: str, kept: list[str], cut: list[str], texts: dict[str, str],
           fail_open: str | None, manual: bool = False) -> str:
    """The text the session reads. Its first lines say WHAT happened and how to ask for more, so a session never
    has to guess whether an empty section list means "Jev dispensed everything" or "something broke"."""
    me = f"python3 \"$GC_CITY_PATH/scripts/jev_preambulo_claim.py\" --bead {bead_id} --role {role} --arm {arm} --all"
    head = ["## Doutrina por tarefa (carregada na reivindicação — ga-aijm2v.13)"]
    if manual:
        head.append("Pedido manual (`--all`): todas as seções opcionais deste papel, sem consultar o Jev.")
    elif fail_open:
        head.append(f"Jev não decidiu ({fail_open}): a doutrina opcional vai COMPLETA, nada foi dispensado.")
    elif cut:
        head.append("O Jev dispensou para esta tarefa: " + ", ".join(cut) + ". "
                    + ("As seções abaixo são as que ficaram." if kept else "Não há seção opcional a ler."))
    else:
        head.append("O Jev não dispensou nenhuma seção opcional: todas abaixo.")
    if cut and not manual:
        head.append(f"Se a tarefa virar algo que uma seção dispensada cobre, rode: `{me}`")
    parts = ["\n".join(head)]
    for sid in kept:
        parts.append(f"<!-- td:{sid} -->\n{texts[sid]}")
    return "\n\n".join(parts) + "\n"


def notice_no_policy(reason: str, role: str | None) -> str:
    """Printed when the loader cannot know which sections the prime withheld. Loud on purpose, and it names the file:
    a session must end up reading the doctrine, not proceeding without it."""
    return (
        "## Doutrina por tarefa — NÃO CARREGADA (ga-aijm2v.13)\n"
        f"O carregador não conseguiu decidir quais seções opcionais faltam ({reason}).\n"
        "Trate TODA a doutrina opcional como pendente: leia o arquivo inteiro antes de seguir —\n"
        f"{fragment_path()}\n"
        f"(papel pedido: {role or 'não informado'}). Procure os blocos marcados `td:<id>` que o seu prime não trouxe.\n"
    )


# ── the decision ───────────────────────────────────────────────────────────────────────
def _run_with_deadline(fn, seconds: float):
    """(value, error). Runs `fn` in a daemon thread and gives up after `seconds`: a Jev call that hangs (or a vault
    lookup that does) must never stall a session's first minute. The abandoned thread is a daemon: it dies with us."""
    box: dict = {}

    def target():
        try:
            box["value"] = fn()
        except BaseException as e:  # noqa: BLE001 - the whole point is that NOTHING escapes into the session
            box["error"] = f"{type(e).__name__}: {e}"

    t = threading.Thread(target=target, daemon=True)
    t.start()
    t.join(seconds)
    if t.is_alive():
        return None, "tempo_esgotado"
    if "error" in box:
        return None, "erro_inesperado: " + box["error"][:200]
    return box["value"], None


def decide(bead_id: str, store: str, role: str, policy: dict, ask=pe.call_jev_noul_multi, read_bead=None) -> dict:
    """{"kept", "cut", "fail_open", "record"}. `record` is the shadow's record when the shadow's code ran, else a
    minimal one; `fail_open` is None when Jev actually decided (even if Jev's answers were partly unusable: those
    sections are kept by decide_sections and say so in record["motivos"]). An unreadable bead is "bead_ilegivel":
    ALL eligible sections kept. NOTE: `store` must be the store that HOLDS the bead; a rig bead (wa-*) asked of the HQ
    store reads as unreadable, which fails open (safe, but that session saves nothing)."""
    read_bead = read_bead or gv._bd_show
    eligible = list(policy["eligible"].get(role) or [])
    # Bead read. vazio (bd found no such bead) and falhou/ilegível (bd down, bad JSON, timeout) are BOTH None here and
    # BOTH land in the same inert state: the full optional doctrine. A task we could not read is not a task with
    # nothing special in it, so we never cut on either.
    bead = read_bead(store, bead_id)
    if not isinstance(bead, dict):
        return {"kept": eligible, "cut": [], "fail_open": "bead_ilegivel",
                "record": _minimal_record(bead_id, store, role, policy, eligible, "bead_ilegivel")}
    ent = {"entity_id": bead_id, "bead": bead, "store": store, "pool": role}
    status, detail = pe.process_entity(ent, policy, ask=ask)
    if status == "skip_no_eligible_sections":  # nothing the prime could have withheld: empty, and that is the truth
        return {"kept": [], "cut": [], "fail_open": None, "record": _minimal_record(bead_id, store, role, policy, [], status)}
    if status != "logged":
        # A status this code was not written for (the shadow's code grew an outcome). That is not "nothing to withhold":
        # we do not know what Jev decided, so the inert state is the full optional doctrine, with the reason named.
        return {"kept": eligible, "cut": [], "fail_open": "estado_desconhecido: " + str(status)[:80],
                "record": _minimal_record(bead_id, store, role, policy, eligible, "estado_desconhecido")}
    rec = detail
    # decide_sections already kept every section in both cases below; naming the reason is what lets the session's
    # header say "Jev did not decide" instead of "Jev dispensed nothing". "parcial" (some answers usable) is NOT a
    # fail-open: the usable answers decided, the unusable ones kept (record["motivos"] says which).
    fail_open = None
    if rec["jev_status"] == "falhou":
        fail_open = "jev_indisponivel: " + str(rec.get("jev_error"))
    elif rec["jev_status"] == "nao_chamado_injecao":
        fail_open = "suspeita_injecao"
    return {"kept": rec["incluidas"], "cut": rec["cortadas"], "fail_open": fail_open, "record": rec}


def _minimal_record(bead_id: str, store: str, role: str, policy: dict, eligible: list[str], jev_status: str) -> dict:
    pt = policy["pt"]
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entity_id": bead_id, "bead": bead_id, "store": store, "pool": role,
        "experiment": pt["experiment"], "jev_status": jev_status, "jev_ok": False, "jev_error": None,
        "jev_tokens_in": 0, "jev_tokens_out": 0, "limiar": pt["threshold"],
        "elegiveis": eligible, "incluidas": eligible, "cortadas": [], "motivos": {s: jev_status for s in eligible},
        "chars_cortados": 0, "tokens_estimados_poupados": 0,
        "chars_doutrina_papel": policy["delivered"].get(role),
    }


def _stamp(rec: dict, *, bead_id: str, arm: str, kept: list[str], cut: list[str], output: str, policy: dict,
           fail_open: str | None, manual: bool, seconds: float) -> dict:
    """Turn a decision record into a LIVE record. The shadow's `arm` (per-bead hash) moves to `arm_hash`; `arm` is
    the session's. `aplicado` = this session really got this list INSTEAD of the full doctrine (experiment arm only)."""
    pt = policy["pt"]
    rec = dict(rec)
    rec.update({
        "mode": MODE_VIVO, "fase": FASE_VIVO, "origem": "reivindicacao",
        "arm_hash": je.assign_arm(bead_id, pt["experiment"]),
        "arm": arm, "aplicado": arm == "experiment",
        "pedido_manual": manual, "falha_aberta": fail_open,
        "alias": os.environ.get("GC_ALIAS") or None,       # the pool slot (gastown.dog-3): the join key with the prime's arm
        "sessao": os.environ.get("GC_SESSION_NAME") or rec.get("sessao"),
        "chars_impressos": len(output),
        "tokens_impressos_estimados": int(round(len(output) / pt["chars_per_token"])),
        "segundos": round(seconds, 2),
    })
    rec["incluidas"], rec["cortadas"] = list(kept), list(cut)
    return rec


def run_claim(*, bead_id: str, store: str, role: str, arm: str, show_all: bool = False, dry_run: bool = False,
              ask=pe.call_jev_noul_multi, read_bead=None, log_path=None, deadline_s: float | None = None,
              policy: dict | None = None) -> tuple[int, str]:
    """(exit code, text for the session's stdout). Never raises. Writes at most one record (not on dry-run/control)."""
    t0 = time.time()
    if arm == "control":
        return 0, ("## Doutrina por tarefa (ga-aijm2v.13): braço controle — a doutrina completa já veio no prime; "
                   "nada a carregar.\n")
    # Policy/fragment read. vazio -> n/a (a manifest with no roles fails `check`, which is a PolicyError);
    # falhou/ilegível -> PolicyError: the notice that names the fragment file and exit 3, never an empty stdout.
    try:
        policy = policy or pe.load_policy()
        texts = section_texts(policy)
    except pe.PolicyError as e:
        return EXIT_NO_POLICY, notice_no_policy(str(e)[:300], role)
    if role not in policy["eligible"]:
        return EXIT_NO_POLICY, notice_no_policy(f"papel desconhecido: {role!r}", role)
    eligible = list(policy["eligible"][role])
    if not eligible:
        return 0, f"## Doutrina por tarefa (ga-aijm2v.13): o papel {role} não tem seção opcional — nada a carregar.\n"
    missing = [s for s in eligible if s not in texts]
    if missing:  # the manifest names a section the fragment lacks: the policy is incoherent, say so loudly
        return EXIT_NO_POLICY, notice_no_policy("seção elegível ausente do fragment: " + ", ".join(missing), role)

    if show_all:
        kept, cut, fail_open, manual = eligible, [], None, True
        rec = _minimal_record(bead_id, store, role, policy, eligible, "pedido_manual")
    else:
        res, err = _run_with_deadline(
            lambda: decide(bead_id, store, role, policy, ask=ask, read_bead=read_bead),
            DEADLINE_S if deadline_s is None else deadline_s)
        manual = False
        if err:  # timed out or blew up: the full optional doctrine, and the log says why
            kept, cut, fail_open = eligible, [], err
            rec = _minimal_record(bead_id, store, role, policy, eligible, err.split(":")[0])
        else:
            kept, cut, fail_open, rec = res["kept"], res["cut"], res["fail_open"], res["record"]
        if fail_open:  # belt and braces: a fail-open NEVER withholds anything, whatever the record says
            kept, cut = eligible, []
    output = render(bead_id, role, arm, kept, cut, texts, fail_open, manual=manual)
    if not dry_run:
        try:
            pe._write(_stamp(rec, bead_id=bead_id, arm=arm, kept=kept, cut=cut, output=output, policy=policy,
                             fail_open=fail_open, manual=manual, seconds=time.time() - t0), log_path)
        except OSError as e:  # the record is evidence, not a precondition: the session still gets its doctrine
            sys.stderr.write(f"jev_preambulo_claim: registro não gravado ({type(e).__name__}: {e})\n")
    return 0, output


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bead", required=True, help="the bead the session just claimed")
    ap.add_argument("--role", required=True, help="TD_ROLE of the session (dog | wa-worker | ps-worker). The prime is what "
                    "withheld the sections, so the role comes from the caller, never from the bead")
    ap.add_argument("--arm", required=True, choices=ARMS, help="the SESSION's arm (decided at prime by pool slot)")
    ap.add_argument("--store", default=None, help="bd store holding the bead (default: $GC_CITY_PATH)")
    ap.add_argument("--all", action="store_true", dest="show_all", help="print every eligible section, no Jev")
    ap.add_argument("--dry-run", action="store_true", help="decide and print, write no record")
    ap.add_argument("--log", default=None, help="record file (tests only; default: the shared Jev experiment log)")
    args = ap.parse_args(argv)
    store = args.store or os.environ.get("GC_CITY_PATH") or gv.DEFAULT_GC_CITY
    code, text = run_claim(bead_id=args.bead, store=store, role=args.role, arm=args.arm, show_all=args.show_all,
                           dry_run=args.dry_run, log_path=args.log)
    sys.stdout.write(text)
    sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(main())
