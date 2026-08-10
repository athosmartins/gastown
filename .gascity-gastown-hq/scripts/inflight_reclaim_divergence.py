#!/usr/bin/env python3
"""inflight_reclaim_divergence.py — compara o veredito de vivacidade do
PAINEL (bead_state.holder_is_alive, o modelo simples usado por derive() para
'executing' vs 'stranded') com o do CONSUMIDOR REAL (as funções ricas de
inflight-reclaim-guard.py: session_is_live / pool_has_live_worker /
concrete_adhoc_session_is_live, dispatched pela mesma forma que run_cycle usa)
— sobre TODAS as beads abertas/in_progress com assignee não-vazio.

REGRA GERAL (per [[to-audit-a-consumer-execute-it-never-reimplement-its-rules]]
e o comparador irmão panel_state_divergence.py, que já pagou o preço de violar
isso uma vez — ~240x de erro): para auditar um consumidor, EXECUTE o
consumidor. Este script IMPORTA e RODA as funções reais de
inflight-reclaim-guard.py — não reimplementa a lógica de despacho por forma de
assignee (bare template / adhoc concreto / crew nomeado).

O que NÃO é comparado aqui (fora do escopo de ga-x3e7p, ver o bead): TTL/
histerese, branch-checking, thrash cap, refusal threshold, mail alerts — tudo
isso é política de reclaim, não interpretação de estado, e usa dados que este
script não tenta reproduzir (relógio de stranding acumulado, git). O que É
comparado é exatamente a pergunta que os dois sistemas hoje respondem de forma
genuinamente independente: "o detentor deste bead está vivo?"

USO:  python3 inflight_reclaim_divergence.py
"""
import json
import os
import subprocess
import sys
import time

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPTS_DIR)

from bead_state import holder_is_alive, claimant_provably_dead  # noqa: E402

import importlib.util as _ilu

_spec = _ilu.spec_from_file_location(
    "irg", os.path.join(_SCRIPTS_DIR, "inflight-reclaim-guard.py"))
irg = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(irg)


def fetch_sessions():
    """Reusa list_active_sessions() do PRÓPRIO consumidor (não reimplementa a
    query) — mesma fonte, mesmo filtro not-closed, para as duas metades da
    comparação partirem do IDÊNTICO snapshot de sessões."""
    sessions = irg.list_active_sessions()
    if sessions is None:
        print("ERRO: gc session list falhou — sem isso a comparação é inválida.",
              file=sys.stderr)
        raise SystemExit(2)
    return sessions


def fetch_assigned_open_beads():
    """HQ + todos os rig stores (ga-mfeip pattern — mesma cobertura que
    list_inflight_beads/list_stranded_inprogress_beads usam), não só HQ.

    ga-x3e7p GATE-FAIL (attempt 4, gate_run=ga-521y0): `_list_rig_stores() or
    []` collapsed its documented 3-state contract (list on success / None
    specifically when `gc rig list` failed) into a silent "proceed HQ-only"
    — indistinguishable from a genuine zero-extra-rigs success, and unlike
    the two sibling failure paths a few lines below (HQ bd-list failure
    raises SystemExit(2); per-rig bd-list failure prints a ⚠️ warning), this
    path emitted NOTHING. Verified by execution (monkeypatched
    _list_rig_stores to return None, ran this function for real): silently
    returned HQ-only beads with zero stderr output — main() could then print
    "zero divergência ... sobre todas as beads abertas" having actually
    audited only 1 of 6+ rig stores. Fixed: None is now its own branch with
    an explicit warning, matching the per-rig failure's own visibility
    convention, before falling back to HQ-only."""
    _rig_stores = irg._list_rig_stores()
    if _rig_stores is None:
        print("⚠️  gc rig list falhou — comparação cobre SOMENTE HQ (rig stores indisponíveis)",
              file=sys.stderr)
        _rig_stores = []
    stores = [(None, None)] + list(_rig_stores)
    all_beads = []
    for rig_name, rig_path in stores:
        cmd = ["bd"] + (["-C", rig_path] if rig_path else []) + [
            "list", "--status", "open,in_progress", "--json", "--limit", "0"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0 or not r.stdout.strip():
            if rig_path is None:
                print("ERRO: bd list (HQ) falhou — sem isso a comparação é inválida.",
                      file=sys.stderr)
                raise SystemExit(2)
            print(f"⚠️  bd list falhou para rig {rig_name!r} ({rig_path}) — pulando "
                  "(fail-open, mesma postura do próprio consumidor por-rig)",
                  file=sys.stderr)
            continue
        data = json.loads(r.stdout)
        for b in data:
            if (b.get("assignee") or "").strip() and (b.get("issue_type") or b.get("type") or "") != "epic":
                b["_rig"] = rig_name or "hq"
                all_beads.append(b)
    return all_beads


def guard_verdict(assignee, sessions, now, bead_update_age):
    """Dispatch EXATAMENTE como run_cycle faz (Pass 1) — mesma forma, mesma
    ordem de decisão — usando as funções REAIS importadas do consumidor."""
    is_bare = assignee in irg.EPHEMERAL_POOL_ASSIGNEES
    is_adhoc = (not is_bare) and irg._is_ephemeral_pool_assignee(assignee)
    if is_bare:
        shape = "bare-pool-template"
        alive = irg.pool_has_live_worker(assignee, sessions, now, bead_update_age)
    elif is_adhoc:
        shape = "concrete-adhoc/dog"
        alive = irg.concrete_adhoc_session_is_live(assignee, sessions, now, bead_update_age)
    else:
        shape = "named-crew"
        alive = irg.session_is_live(assignee, sessions, now, bead_update_age)
    return shape, alive


def main():
    sessions = fetch_sessions()
    beads = fetch_assigned_open_beads()
    live_names = frozenset(
        idv for s in sessions
        for idv in (s.get("id", ""), s.get("name", ""), s.get("session_name", ""),
                    s.get("alias", ""), s.get("agent_name", ""))
        if idv
    )
    now = time.time()

    print(f"sessões vivas (não-closed): {len(sessions)}")
    print(f"beads open/in_progress com assignee (HQ + rigs, não-epic): {len(beads)}")
    print()
    header = "%-12s %-8s %-22s %-18s %-8s %-8s %-12s %s"
    print(header % ("BEAD", "RIG", "ASSIGNEE", "FORMA", "PAINEL", "GUARDA", "PROV.MORTO", "DIVERGE?"))
    print("-" * 108)

    divergences = []
    coordinator_rows = []
    for b in beads:
        bid = b.get("id", "")
        assignee = b.get("assignee") or ""
        updated_at = b.get("updated_at", "")
        bead_update_epoch = irg.parse_iso_epoch(updated_at)
        bead_update_age = (now - bead_update_epoch) if bead_update_epoch is not None else None

        dashboard_alive = holder_is_alive(assignee, live_names)
        shape, guard_alive = guard_verdict(assignee, sessions, now, bead_update_age)
        prov_dead = claimant_provably_dead(assignee, sessions)

        # holder_is_alive() tem contrato documentado de 3 estados
        # (True/False/None). `live_names` sempre vem de sessões REAIS já
        # consultadas (fetch_sessions aborta em vez de seguir com dados
        # ausentes), mas isso cobre só METADE do contrato None: a outra
        # metade é is_coordinator(assignee)==True, independente de sessões
        # terem sido consultadas (bead_state.py's próprio docstring: "None,
        # não True: nunca verificamos vivacidade de fato para um
        # coordenador"). ga-x3e7p GATE-FAIL (attempt 2/3): a versão anterior
        # tratava esse 3º valor como impossível (assert) e CRASHAVA na 1ª
        # bead com assignee coordenador da população viva — confirmado:
        # ga-7j5vf, assignee=mayor, status=open, passa por todo filtro de
        # fetch_assigned_open_beads().
        #
        # Painel e guarda respondem perguntas DIFERENTES para coordenador —
        # painel: "não avaliei, é papel sempre-ligado" (None); guarda:
        # "False deliberado, nunca conta como builder vivo, protegido por
        # outro rail" (ver session_is_live()/concrete_adhoc_session_is_live(),
        # ambas com "Returning True there left dead-builder beads parked
        # under the Mayor permanently un-reclaimable"). Não é a MESMA
        # pergunta discordando — forçar None contra bool na comparação
        # binária abaixo classificaria isso como "divergência" junto de
        # desacordos REAIS, escondendo a distinção. Categoria própria,
        # fora da lista de divergências.
        if dashboard_alive is None:
            coordinator_rows.append((bid, assignee, shape, guard_alive, prov_dead))
            print(header % (bid, b.get("_rig", "hq"), assignee[:22], shape,
                             "N/A(coord)", str(guard_alive), str(prov_dead), ""))
            continue

        diverges = dashboard_alive is not guard_alive
        if diverges:
            divergences.append((bid, assignee, shape, dashboard_alive, guard_alive, prov_dead))

        print(header % (bid, b.get("_rig", "hq"), assignee[:22], shape, str(dashboard_alive),
                         str(guard_alive), str(prov_dead), "⚠️ SIM" if diverges else ""))

    print()
    if not divergences:
        print("✅ zero divergência entre painel (holder_is_alive) e guarda "
              "(session_is_live/pool_has_live_worker/concrete_adhoc_session_is_live) "
              "sobre todas as beads abertas com assignee.")
    else:
        print(f"⭐ {len(divergences)} DIVERGÊNCIA(S) — painel e guarda discordam "
              "sobre se o detentor está vivo:")
        for bid, assignee, shape, dash, guard, prov in divergences:
            print(f"   {bid}: assignee={assignee!r} forma={shape} "
                  f"painel={dash} guarda={guard} provavelmente_morto={prov}")
    if coordinator_rows:
        print()
        print(f"ℹ️  {len(coordinator_rows)} bead(s) com assignee coordenador — painel não "
              "avalia vivacidade (None por desenho), não contado como divergência:")
        for bid, assignee, shape, guard, prov in coordinator_rows:
            print(f"   {bid}: assignee={assignee!r} forma={shape} "
                  f"guarda={guard} provavelmente_morto={prov}")


if __name__ == "__main__":
    main()
