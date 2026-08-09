#!/usr/bin/env python3
"""Testes de bead_state.py — a derivação canônica de estado da cidade.

Cada teste aqui corresponde a um erro REAL medido, não a um caso imaginado. Um
módulo do qual 10 consumidores vão depender não pode ter o seu comportamento
definido só pelo primeiro que o leu.

    python3 -m pytest scripts/test_bead_state.py -q
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bead_state import derive, holder_is_alive, is_athos_page  # noqa: E402

CREWS = frozenset({"mila-wa", "oracle-wa", "batista-wa", "batista-ps", "mayor"})


def b(**kw):
    d = {"status": "open", "labels": [], "assignee": "", "metadata": {}}
    d.update(kw)
    return d


# ── vivacidade ───────────────────────────────────────────────────────────────
# Falso-positivo medido 09/08: mila-wa-awispm94omdp estava VIVA e o bead wa-o2zv3
# (assignee 'mila-wa') foi classificado 'stranded' — igualdade exata não casa sufixo.

def test_holder_alive_casa_sessao_com_sufixo():
    assert holder_is_alive("mila-wa", frozenset({"mila-wa-awispm94omdp"})) is True


def test_holder_alive_casa_igualdade_exata():
    assert holder_is_alive("mila-wa", frozenset({"mila-wa"})) is True


def test_holder_alive_falso_quando_ninguem_bate():
    assert holder_is_alive("mila-wa", frozenset({"oracle-wa-x1"})) is False


def test_lista_ausente_e_NAO_CONSULTEI_nao_ninguem_vivo():
    """None ≠ frozenset(). Fonte incompleta (só tmux) já me fez chamar de abandonado
    um reviewer VIVO fora do tmux (PID 34105). 'Não sei' precisa ser um 3º valor."""
    assert holder_is_alive("mila-wa", None) is None
    assert holder_is_alive("mila-wa", frozenset()) is False


def test_in_progress_sem_consultar_vivacidade_NAO_e_stranded():
    st = derive(b(status="in_progress", assignee="mila-wa"), None, CREWS)
    assert st["state"] == "executing"
    assert "liberar_para_pool" not in st["actions"]


def test_in_progress_com_prova_de_morte_e_stranded():
    st = derive(b(status="in_progress", assignee="mila-wa"), frozenset(), CREWS)
    assert st["state"] == "stranded"
    assert st["actions"] == ["liberar_para_pool"]


def test_gate_failed_nao_devolve_pro_pool_sem_prova_de_morte():
    """A ação irreversível deste módulo é tirar o bead de quem o segura. Ela exige
    PROVA de óbito, nunca ausência de informação."""
    st = derive(b(status="open", labels=["gate:needs-fix"], assignee="mila-wa"), None, CREWS)
    assert "devolver_pro_pool" not in st["actions"]
    st2 = derive(b(status="open", labels=["gate:needs-fix"], assignee="mila-wa"), frozenset(), CREWS)
    assert "devolver_pro_pool" in st2["actions"]


# ── de quem é a vez ──────────────────────────────────────────────────────────

def test_policy_gap_e_do_athos():
    assert is_athos_page(["refino:policy-gap"]) is True


def test_gate_needs_human_so_product_e_do_athos():
    assert is_athos_page(["gate:needs-human:product"]) is True
    assert is_athos_page(["gate:needs-human:technical"]) is False
    assert is_athos_page(["gate:needs-human"]) is False


def test_escalacao_sem_classificacao_NAO_e_do_athos():
    """ga-n77jl (09/08): feature migrada do ClickUp, descrição completa, zero
    perguntas — estava na coluna do Athos sem nenhum botão possível."""
    st = derive(b(labels=["auto-refino:escalated", "story:refino-escalado"]), None, CREWS)
    assert st["turn"] == "mayor"
    assert st["state"] == "backlog"


def test_decisao_do_athos_ganha_de_park():
    """Contrato das colunas: um bead que precisa do Athos NUNCA pode estar em
    Travadas. Quem destrava é a decisão dele, então ela vence o bloqueio."""
    st = derive(b(labels=["blocked:needs-oracle-approval", "story:needs-approval"]), None, CREWS)
    assert st["turn"] == "athos"


def test_nao_sei_de_quem_e_resolve_pro_mayor_nunca_pro_athos():
    """A REGRA DE OURO do módulo. Foi a inversão dela que produziu o sintoma."""
    assert derive(b(labels=["exec:manual"]), None, CREWS)["turn"] == "mayor"
    assert derive(b(status="qualquer-coisa-nao-mapeada"), None, CREWS)["turn"] == "mayor"


def test_nenhum_estado_resolve_pro_athos_sem_label_de_pagina():
    """Varredura: nenhuma combinação sem label de página pode virar vez do Athos."""
    for labels in ([], ["ctx:ready", "exec:auto"], ["gate:queued"], ["story:approved"],
                   ["blocked:x"], ["gate:needs-fix"], ["ctx:thin"], ["exec:manual"],
                   ["auto-refino:escalated"], ["gate:needs-human:technical"]):
        for status in ("open", "in_progress", "deferred", "hooked", "pinned"):
            st = derive(b(status=status, labels=list(labels), assignee="mila-wa"), None, CREWS)
            assert st["turn"] != "athos", (labels, status, st)


def test_closed_e_terminal():
    assert derive(b(status="closed"), None, CREWS)["turn"] == "nobody"
