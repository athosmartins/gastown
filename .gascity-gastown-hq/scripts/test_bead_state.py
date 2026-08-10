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
from bead_state import derive, holder_is_alive, is_athos_page, is_ephemeral  # noqa: E402

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


# ── gate ativo: label vs marker (ga-zltsr, 10/08) ───────────────────────────────
# gate:queued sobrevive ao marker fechar — só 2 call sites de 'label remove ...
# gate:queued' no pipeline inteiro, contra 12 de gate:reviewing. Confirmado em
# produção: wa-nh37r carregava gate:queued com ZERO marker referenciando.

def test_gate_active_label_sozinho_quando_chamador_nao_verificou():
    """Comportamento pré-existente preservado: sem gate_active (None), a decisão
    cai no heurístico de label bruto — igual a antes desta bead."""
    st = derive(b(labels=["gate:queued"]), None, CREWS)
    assert st["state"] == "at_gate"


def test_gate_active_false_verificado_vence_label_obsoleto():
    """O caso wa-nh37r: label gate:queued sobrevivendo ao marker já fechado. Um
    chamador que VERIFICOU via marker e não achou nada precisa poder dizer que
    NÃO está no gate, mesmo com o label ainda presente."""
    st = derive(b(status="in_progress", labels=["gate:queued"], assignee="mila-wa"),
                frozenset({"mila-wa"}), CREWS, gate_active=False)
    assert st["state"] != "at_gate"
    assert st["state"] == "executing"


def test_gate_active_true_verificado_mesmo_sem_label():
    """Direção oposta: marker já ativo, label ainda não aplicado — o mesmo lag que
    faz pilot-dispatcher.sh's _filter_built() usar OR entre marker e label."""
    st = derive(b(labels=[]), None, CREWS, gate_active=True)
    assert st["state"] == "at_gate"


def test_gate_active_none_nunca_colapsa_pra_false():
    """Convenção do módulo inteiro: None (não verifiquei) nunca vira o mesmo
    resultado que False (verifiquei e não está ativo). Com label presente, None
    preserva o heurístico (at_gate); só um False EXPLÍCITO derruba."""
    with_label = b(labels=["gate:reviewing"])
    assert derive(with_label, None, CREWS, gate_active=None)["state"] == "at_gate"
    assert derive(with_label, None, CREWS, gate_active=False)["state"] != "at_gate"


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


# ── absorvido de pilot-dispatcher.sh (ga-7qsxr, 09/08) ─────────────────────────
# Catalogados lendo o arquivo inteiro (300 refs, 3 leituras independentes por trecho)
# antes de qualquer troca de lógica local por derive() — ordem exigida pelo bead.

def test_gate_needs_human_qualquer_sufixo_e_park_exceto_product():
    """pilot-dispatcher.sh veta gate:needs-human* (10+ call sites) independente do
    sufixo; só :product é vez do Athos (is_athos_page, regra 3, roda antes do park).
    Sem isto derive() dizia 'ready'/'backlog' pra uma bead que o Pilot nunca
    despacharia — custo medido: ga-3lsy1 dispatched 4x apesar do label desde a
    criação."""
    st_technical = derive(b(labels=["ctx:ready", "exec:auto", "gate:needs-human:technical"]),
                           None, CREWS)
    assert st_technical["state"] == "parked"
    assert st_technical["turn"] == "mayor"

    st_bare = derive(b(status="in_progress", labels=["gate:needs-human"], assignee="mila-wa"),
                      frozenset({"mila-wa"}), CREWS)
    assert st_bare["state"] == "parked"

    st_product = derive(b(labels=["gate:needs-human:product"]), None, CREWS)
    assert st_product["turn"] == "athos"
    assert st_product["state"] != "parked"


def test_needs_human_bare_prefix_bugs_tech_debt_e_park():
    """Vocabulário separado de gate:needs-human — usado por bugs/tech-debt sem o
    prefixo gate: (ga-3lsy1)."""
    st = derive(b(labels=["needs-human-followup"]), None, CREWS)
    assert st["state"] == "parked"


def test_pilot_held_count_bookkeeping_nao_colide_com_park():
    """ACHADO MAIS URGENTE da sessão: pilot:held-count:<slug>:<n> (contador de
    escalação de _pilot_hold_or_escalate, NUNCA limpo) colidia com o antigo prefixo
    bare 'pilot:held' em PARK_PREFIXES — uma bead segurada UMA VEZ ficava 'parked'
    pra SEMPRE, mesmo muito depois de despachada/mergeada, porque park (regra 4) é
    checado antes de executing/at_gate/gate_failed (regras 5-7). Já afeta o painel
    em produção (1º consumidor migrado)."""
    st = derive(b(status="in_progress", labels=["pilot:held-count:ga-lfvs6:1"],
                  assignee="mila-wa"),
                frozenset({"mila-wa"}), CREWS)
    assert st["state"] != "parked"
    assert st["state"] == "executing"


def test_pilot_held_e_held_until_continuam_parkeando():
    """Regressão-guarda para o fix acima: o par LEGÍTIMO (pilot:held bare +
    pilot:held-until:<epoch>, escritos juntos por _mayor_deferred_hold_db) precisa
    continuar parkeando — só o contador de bookkeeping deixa de colidir."""
    assert derive(b(labels=["pilot:held"]), None, CREWS)["state"] == "parked"
    assert derive(b(labels=["pilot:held-until:1786400000"]), None, CREWS)["state"] == "parked"


def test_story_triage_e_unrefined():
    """Agrupada com story:unrefined/story:refinement-in-progress em
    pilot-dispatcher.sh's _FILTER_PREAPPROVAL_LABELS — mesma guarda-chuva
    pré-aprovação."""
    assert derive(b(labels=["story:triage"]), None, CREWS)["state"] == "unrefined"


def test_ephemeral_formas_nuas_do_pool_template():
    """'wa-worker'/'ps-worker'/'gastown.dog' SEM sufixo não batiam nenhum marker
    substring existente (falta o traço final) — pilot-dispatcher.sh já as tratava
    como efêmeras explicitamente (padrão bash case, 2 call sites). Sem isto,
    crew_of() resolveria a forma nua como se fosse um crew real."""
    assert is_ephemeral("gastown.dog") is True
    assert is_ephemeral("wa-worker") is True
    assert is_ephemeral("ps-worker") is True
    # formas sufixadas já cobertas pelos markers substring existentes — regressão-guarda
    assert is_ephemeral("wa-worker-adhoc-xyz") is True
    assert is_ephemeral("gastown.dog-3") is True
    # não deve super-generalizar para nomes de crew reais
    assert is_ephemeral("mila-wa") is False


def test_outros_labels_park_absorvidos_de_pilot_dispatcher():
    """story:blocked, type:future, cost-decision, prod-experiment, ban-risk,
    engine-window:pending, waiting-on:/depends-on: — cada um com pelo menos um
    call site real em pilot-dispatcher.sh, ausentes do vocabulário canônico até
    ga-7qsxr. Direção aditiva/segura: pior caso é 'não despachou', nunca
    double-dispatch."""
    for labels in (["story:blocked"], ["type:future"], ["cost-decision"],
                   ["prod-experiment"], ["ban-risk"], ["engine-window:pending"],
                   ["waiting-on:ga-xyz"], ["depends-on:ga-xyz"]):
        assert derive(b(labels=labels), None, CREWS)["state"] == "parked", labels
