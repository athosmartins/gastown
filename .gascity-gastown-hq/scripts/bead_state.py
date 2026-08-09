#!/usr/bin/env python3
"""bead_state.py — a ÚNICA derivação canônica de estado de bead da cidade.

POR QUE ISTO EXISTE (medido 2026-08-09, Mayor):
Dez consumidores de produção implementam, cada um, o seu próprio interpretador dos
labels de estado — pilot-dispatcher.sh (300 refs), inflight-reclaim-guard.py (262),
approved-state-reconciler.py (249), painel_visibilidade.py (237),
lifecycle-coherence-janitor.sh (200), quality-gate-dispatcher.sh (134),
context-check-dispatcher.sh (90), pilot-missing-route-watchdog.sh (81),
quality-gate-guard.sh (80), throughput-stall-watchdog.py (66).

Não existe fonte única. Consequência medida em UM dia:
  · 5 vigias com vocabulário de park INCOMPLETO, cada um com uma lista diferente
    (probe sem exec:manual; reconciler sem ctx:thin; stall-watchdog sem
    awaiting-external-merge; context-check cego a TODO label de park; meu próprio
    sweep sem 'blocked:')
  · park que não gruda: quem parkeia acerta um consumidor e erra os outros
  · painel mostrando "em execução" trabalho terminado e trabalho de agente morto
  · exec:manual sem executor caindo na coluna do Athos sem ação possível — 3 casos
    novos em 24h, o mais recente 1h atrás
Cada defeito foi uma DISCORDÂNCIA entre dois interpretadores. O número de pares
cresce com o quadrado do número de consumidores.

O QUE ISTO DEVOLVE, e é o contrato:
  state   — o estado canônico do ciclo de vida
  turn    — DE QUEM é a vez (athos | mayor | crew:<nome> | pool | external | nobody)
  actions — o que é possível fazer AGORA, já checado contra fato de runtime
  reasons — por que cada ação indisponível está indisponível (texto pra humano)

⚠️ REGRA DE OURO: `turn == "athos"` SÓ quando existe uma ação que apenas ele pode
tomar. "Não sei de quem é" NUNCA resolve pra ele — resolve pra `mayor` (triagem).
Foi a inversão desse default que produziu o sintoma que o Athos reportou.

USO:
    from bead_state import derive
    st = derive(bead_dict, live_sessions=set(...), known_crews=set(...))
    st["turn"], st["state"], st["actions"]

Sem I/O: `derive` é PURA. Quem chama passa os fatos de runtime (sessões vivas,
crews conhecidos). Isso mantém a função testável e impede o erro de hoje — decidir
sobre um valor de runtime que nunca foi consultado.
"""
from __future__ import annotations

# ── vocabulário canônico ─────────────────────────────────────────────────────
# Uma única lista por conceito. Consumidor NÃO mantém a sua cópia — importa daqui.

PARK_PREFIXES = (
    "blocked:", "blocked-on:", "blocked-by:", "pool:refused", "pilot:refused",
    "needs:engine-window", "pilot:held",
)
PARK_EXACT = frozenset({
    "framework:engine", "no-auto-dispatch", "pilot:no-auto-dispatch",
    "story:awaiting-external-merge", "on-device", "story:needs-device", "phone-proxy",
})
# Estágios de refino: o bead ainda não é construível.
UNREFINED = frozenset({
    "ctx:thin", "story:unrefined", "story:epic",
    "story:refinement-in-progress", "refino:policy-gap", "refino:info-gap",
})
ARMED = frozenset({"ctx:ready", "exec:auto"})
GATE_ACTIVE = frozenset({"gate:queued", "gate:reviewing", "gate:needs-rebase"})
GATE_FAILED = frozenset({"gate:failed", "gate:needs-fix"})
ATHOS_TURN = frozenset({
    "story:needs-approval", "next-action:athos", "blocked-reason:decision",
})

EPHEMERAL_MARKERS = ("-adhoc-", "claude-headless", "wa-worker-", "ps-worker-", "dog-")


def _labels(bead) -> frozenset:
    return frozenset(bead.get("labels") or [])


def _has_prefix(labels, prefixes) -> str | None:
    for l in labels:
        for p in prefixes:
            if l.startswith(p):
                return l
    return None


def is_ephemeral(actor: str) -> bool:
    """Worker efêmero NÃO é crew. Confundir os dois foi a causa do 'claude-wa'
    inexistente que quebrou o botão Cutucar (medido 09/08)."""
    return bool(actor) and any(m in actor for m in EPHEMERAL_MARKERS)


def crew_of(actor: str, known_crews: frozenset) -> str | None:
    """Resolve um actor para um crew REAL, ou None. Valida contra a lista viva —
    nunca devolve nome derivado sem existência confirmada."""
    if not actor or is_ephemeral(actor):
        return None
    if actor in known_crews:
        return actor
    base = actor.split("-adhoc-")[0].split("-ga")[0]
    return base if base in known_crews else None


def derive(bead: dict, live_sessions: frozenset = frozenset(),
           known_crews: frozenset = frozenset(),
           merged: bool | None = None) -> dict:
    """Estado canônico. PURA — todo fato de runtime entra por parâmetro.

    merged: True/False se o chamador verificou o merge; None = não verificou.
            None NUNCA é tratado como False (erro ≠ vazio).
    """
    L = _labels(bead)
    status = bead.get("status") or ""
    assignee = bead.get("assignee") or ""
    holder_alive = bool(assignee) and assignee in live_sessions
    actions, reasons = [], {}

    def offer(name, ok, why=""):
        (actions.append(name) if ok else reasons.setdefault(name, why))

    # 1. TERMINAL
    if status == "closed":
        return {"state": "closed", "turn": "nobody", "actions": [], "reasons": {}}

    # 2. ENTREGUE, AGUARDANDO FECHAMENTO — passou no gate E mergeou. NÃO é execução.
    if "gate:passed" in L and merged is True:
        scope_open = "scope:needs-review" in L or "delivery:partial" in L
        if scope_open:
            offer("escopo_completo_fechar", True)
            offer("falta_parte_reabrir", True)
            return {"state": "delivered_scope_review", "turn": "crew:" + (crew_of(assignee, known_crews) or "?")
                    if crew_of(assignee, known_crews) else "mayor",
                    "actions": actions, "reasons": reasons}
        offer("fechar", True)
        return {"state": "delivered_pending_close",
                "turn": "crew:" + crew_of(assignee, known_crews) if crew_of(assignee, known_crews) else "mayor",
                "actions": actions, "reasons": reasons}

    # 3. PARK EXPLÍCITO — decisão deliberada de não andar.
    park = _has_prefix(L, PARK_PREFIXES) or next((l for l in L if l in PARK_EXACT), None)
    if park or status == "deferred":
        ext = "story:awaiting-external-merge" in L or park == "blocked:external-quota-motherduck"
        return {"state": "parked", "turn": "external" if ext else "mayor",
                "actions": ["despausar"], "reasons": {"despausar": f"parkeado por {park or 'status=deferred'}"}}

    # 4. VEZ DO ATHOS — só quando há ação que SÓ ele toma.
    if L & ATHOS_TURN:
        offer("aprovar", True); offer("rejeitar", True)
        return {"state": "awaiting_athos", "turn": "athos", "actions": actions, "reasons": reasons}

    # 5. GATE REPROVOU — vez de quem constrói, não do Athos.
    if L & GATE_FAILED:
        crew = crew_of(assignee, known_crews) or crew_of(bead.get("owner") or "", known_crews)
        offer("cutucar_crew", bool(crew), "nenhum crew real identificável (assignee é efêmero e owner não resolve)")
        offer("devolver_pro_pool", not holder_alive, f"{assignee} está VIVO e trabalhando nesta bead")
        offer("regatear", False, "nada mudou no código desde a reprovação — re-gatear reprova igual")
        return {"state": "gate_failed", "turn": ("crew:" + crew) if crew else "mayor",
                "actions": actions, "reasons": reasons}

    # 6. NO GATE
    if L & GATE_ACTIVE:
        return {"state": "at_gate", "turn": "nobody", "actions": [], "reasons": {}}

    # 7. EM EXECUÇÃO — exige detentor VIVO. Sem isso, não está sendo executado.
    if status == "in_progress":
        if holder_alive:
            return {"state": "executing", "turn": "crew:" + (crew_of(assignee, known_crews) or assignee),
                    "actions": ["cutucar"], "reasons": {}}
        return {"state": "stranded", "turn": "mayor",
                "actions": ["liberar_para_pool"],
                "reasons": {}}

    # 8. NÃO REFINADO
    if L & UNREFINED:
        return {"state": "unrefined", "turn": "mayor", "actions": ["refinar"], "reasons": {}}

    # 9. exec:manual — o balde. O executor DEFINE de quem é a vez.
    if "exec:manual" in L:
        crew = crew_of(assignee, known_crews)
        if crew:
            return {"state": "manual_assigned", "turn": "crew:" + crew, "actions": ["cutucar"], "reasons": {}}
        # ⭐ SEM EXECUTOR: vai pra TRIAGEM DO MAYOR, nunca pro Athos.
        return {"state": "manual_unrouted", "turn": "mayor",
                "actions": ["nomear_executor"],
                "reasons": {"_diagnostico": "exec:manual sem executor — 'não sei quem' NÃO é 'o Athos faz'"}}

    # 10. ARMADO E DESPACHÁVEL
    if ARMED <= L:
        routed = (bead.get("metadata") or {}).get("gc.routed_to")
        if not routed:
            return {"state": "armed_unrouted", "turn": "mayor", "actions": ["rotear"], "reasons": {}}
        return {"state": "ready", "turn": "pool", "actions": [], "reasons": {}}

    # 11. PINNED — nota de referência permanente. Não é trabalho.
    if status == "pinned" or "pinned" in L:
        return {"state": "pinned", "turn": "nobody", "actions": [], "reasons": {}}

    # 12. HOOKED — trabalho no hook de um agente, aguardando ele pegar.
    if status == "hooked":
        crew = crew_of(assignee, known_crews)
        return {"state": "hooked", "turn": ("crew:" + crew) if crew else "pool",
                "actions": ["cutucar"] if crew else [], "reasons": {}}

    # 13. APROVADO MAS NÃO ARMADO — decisão de produto já tomada; falta armar.
    if "story:approved" in L:
        return {"state": "approved_unarmed", "turn": "mayor", "actions": ["armar"], "reasons": {}}

    # 14. BACKLOG — filado, ainda não aprovado nem armado. Vez de quem refina/prioriza.
    if status == "open":
        return {"state": "backlog", "turn": "mayor", "actions": ["refinar", "priorizar"], "reasons": {}}

    # 15. DESCONHECIDO — default é o Mayor, jamais o Athos.
    return {"state": "unknown", "turn": "mayor", "actions": ["triar"],
            "reasons": {"_diagnostico": "estado não classificável pelo modelo canônico"}}
