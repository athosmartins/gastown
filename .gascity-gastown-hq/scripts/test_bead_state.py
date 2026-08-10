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
from bead_state import (  # noqa: E402
    derive, holder_is_alive, is_athos_page, is_ephemeral, is_needs_human,
    claimant_provably_dead, session_owner_is_healthy, session_activity_age,
    parse_iso_epoch, is_coordinator, EPHEMERAL_POOL_TEMPLATES, STALE_ACTIVITY_TTL,
)

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


# ── coordenador (mayor/deacon) nunca é stranded (ga-8lrud) ─────────────────────
# Absorvido de inflight-reclaim-guard.py's COORDINATOR_MARKERS/is_coordinator
# (scripts/inflight-reclaim-guard.py:289-294,1144-1152), que lifecycle-coherence-
# janitor.sh's R4/R7 já refletiam com uma exclusão hardcoded de "mayor" (prova de
# que consumidores de produção já tinham aprendido a lição; o modelo canônico não).
# A sessão viva se chama "gastown.mayor"/"gastown.deacon" — um PREFIXO diferente
# do assignee bare "mayor"/"deacon" que o casamento por sufixo de holder_is_alive
# não cobre — então SEM esta guarda um bead in_progress do mayor/deacon resolvia
# alive=False -> "stranded". Nenhum bead in_progress de mayor/deacon existia no
# momento da medição (09/08) — gap latente, não incidente vivo.

def test_is_coordinator_casa_por_substring_mesmo_vocabulario_do_guard():
    assert is_coordinator("mayor") is True
    assert is_coordinator("deacon") is True
    assert is_coordinator("gastown.mayor") is True
    assert is_coordinator("gastown.deacon") is True
    assert is_coordinator("mila-wa") is False
    assert is_coordinator("") is False


def test_holder_alive_coordenador_e_none_nao_false_mesmo_sem_sessao_correspondente():
    """A sessão real é 'gastown.mayor', não 'mayor' — o casamento por sufixo
    (s==assignee / s.startswith(assignee+'-') / assignee.startswith(s+'-')) não
    bate nenhum dos dois. Sem a guarda de is_coordinator, isto cairia no loop e
    devolveria False (ninguém bate)."""
    live = frozenset({"gastown.mayor", "gastown.deacon", "mila-wa-x1"})
    assert holder_is_alive("mayor", live) is None
    assert holder_is_alive("deacon", live) is None


def test_holder_alive_coordenador_protegido_mesmo_com_lista_de_sessoes_vazia():
    """Mesma semântica de claimant_provably_dead: coordenador nunca é 'comprovadamente
    morto', mesmo quando a consulta de sessões devolve vazio (CONSULTEI E NÃO HÁ
    NINGUÉM para qualquer outro assignee — mas coordenador é exceção antes do loop)."""
    assert holder_is_alive("mayor", frozenset()) is None


def test_in_progress_do_coordenador_nunca_e_stranded():
    """O teste que teria pegado o gap antes de virar incidente: R4/R7 do janitor já
    protegiam 'mayor' na prática — este é o mesmo invariante no modelo canônico."""
    live = frozenset({"gastown.mayor", "mila-wa-x1"})
    st = derive(b(status="in_progress", assignee="mayor"), live, CREWS)
    assert st["state"] == "executing"
    assert "liberar_para_pool" not in st["actions"]
    st2 = derive(b(status="in_progress", assignee="deacon"), live, CREWS)
    assert st2["state"] == "executing"
    assert "liberar_para_pool" not in st2["actions"]


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

# ── needs-human: ga-x3e7p (absorvido de inflight-reclaim-guard.py) ───────────
# Gap real: o CONSUMIDOR (inflight-reclaim-guard.py's _has_needs_human_label)
# tinha seu PRÓPRIO interpretador privado deste vocabulário — exatamente a
# doença que bead_state.py existe pra curar. is_needs_human() é o substituto
# canônico, chamado DIRETAMENTE pelo consumidor (sem passar por derive()).
#
# ⚠️ CORREÇÃO (gate_run=ga-b5y6y, code review): uma versão anterior deste
# comentário afirmava que bead_state.py/PARK não classificava NENHUMA forma
# disso antes de is_needs_human() existir — falso. PARK_PREFIXES já cobria
# bare 'gate:needs-human' e 'needs-human' (qualquer sufixo, via raw
# startswith) desde o commit-pai direto desta branch (cfc0da088/ga-7qsxr) —
# ver test_gate_needs_human_qualquer_sufixo_e_park_exceto_product e
# test_needs_human_bare_prefix_bugs_tech_debt_e_park logo acima, ambos
# escritos ANTES desta seção. Em derive()'s passo 4, `needs_human` é hoje
# redundante com `park` (nunca é a razão decisiva) — mantido como rede de
# segurança contra uma futura remoção das entradas de PARK_PREFIXES (ver
# test_needs_human_wiring_e_load_bearing_independente_de_park_prefixes,
# que prova a wiring load-bearing simulando esse cenário).

def test_is_needs_human_pega_todas_as_variantes():
    assert is_needs_human(["needs-human"]) is True
    assert is_needs_human(["gate:needs-human"]) is True
    assert is_needs_human(["gate:needs-human:technical"]) is True
    assert is_needs_human(["gate:needs-human:on-device"]) is True
    assert is_needs_human(["gate:needs-human:product"]) is True  # também é vez do Athos, via is_athos_page
    assert is_needs_human(["ctx:ready", "exec:auto"]) is False
    assert is_needs_human([]) is False


def test_needs_human_nao_product_e_parked_nao_executing():
    """Hoje esta cobertura vem de PARK_PREFIXES (bare 'gate:needs-human',
    qualquer sufixo — cfc0da088/ga-7qsxr), não da wiring de needs_human em
    derive() — is_needs_human() sozinho é redundante aqui HOJE (ver
    test_needs_human_wiring_e_load_bearing_independente_de_park_prefixes para
    o cenário em que ele passaria a ser decisivo). Continua útil como
    regression-guard end-to-end via derive(), agora com a causa correta
    documentada em vez da alegação original (falsa) de que nada parqueava
    isto antes de is_needs_human()."""
    st = derive(b(status="in_progress", labels=["gate:needs-human:technical"],
                   assignee="mila-wa"), frozenset(), CREWS)
    assert st["state"] == "parked"
    assert st["turn"] == "mayor"


def test_needs_human_bare_tambem_e_parked():
    """Mesma causa que o teste acima (PARK_PREFIXES, não a wiring) — mas para
    a forma bare 'needs-human' isolada, caso não coberto por nenhum teste
    anterior a esta seção (test_needs_human_bare_prefix_bugs_tech_debt_e_park
    só exercitava a variante sufixada 'needs-human-followup')."""
    st = derive(b(status="in_progress", labels=["needs-human"], assignee="mila-wa"),
                frozenset(), CREWS)
    assert st["state"] == "parked"


def test_needs_human_wiring_e_load_bearing_independente_de_park_prefixes():
    """A wiring de needs_human em derive()'s passo 4 é redundante com o
    conteúdo ATUAL de PARK_PREFIXES — mas não é código morto: é rede de
    segurança para o dia em que essas 2 entradas ("gate:needs-human",
    "needs-human") forem removidas de PARK_PREFIXES (ex.: alguém as julgar
    duplicadas de is_needs_human() e "limpar"). Simula esse cenário via
    monkeypatch do módulo e prova que needs_human SOZINHO — sem nenhuma ajuda
    de PARK_PREFIXES — ainda força 'parked'. Sem este teste, as duas asserções
    acima passariam mesmo que a wiring fosse deletada (elas testam o
    RESULTADO de derive(), que PARK_PREFIXES já garante sozinho); este é o
    único teste que distingue "a wiring existe e funciona" de "a wiring
    poderia ser apagada sem quebrar nada visível hoje"."""
    import bead_state
    original = bead_state.PARK_PREFIXES
    try:
        bead_state.PARK_PREFIXES = tuple(
            p for p in original if p not in ("gate:needs-human", "needs-human")
        )
        st = derive(b(status="in_progress", labels=["gate:needs-human:technical"],
                       assignee="mila-wa"), frozenset(), CREWS)
        assert st["state"] == "parked"
        assert st["reasons"]["despausar"] == "parkeado por needs-human"

        st_bare = derive(b(status="in_progress", labels=["needs-human"],
                            assignee="mila-wa"), frozenset(), CREWS)
        assert st_bare["state"] == "parked"
    finally:
        bead_state.PARK_PREFIXES = original


def test_needs_human_product_ainda_ganha_de_park_via_athos_page():
    """':product' é dupla cidadania (is_needs_human E is_athos_page), mas
    is_athos_page roda ANTES (passo 3) — a vez dele tem que vencer, não parked."""
    st = derive(b(labels=["gate:needs-human:product"]), None, CREWS)
    assert st["turn"] == "athos"
    assert st["state"] == "awaiting_athos"


# ── claimant_provably_dead: porta 1:1 dos CPD-1..10 de inflight-reclaim-guard.py
# (ga-x3e7p) — contrato ESTRITAMENTE mais forte que 'not alive': só True quando
# TODO match é estado morto, ou não há match algum. Ambíguo (estado
# desconhecido) e vivo-mas-quieto (zumbi congelado) são False — a decisão de
# reclamar rápido não pode se basear neles.

def _sess(**kw):
    d = {"id": "", "name": "", "session_name": "", "alias": "", "agent_name": "",
         "template": "", "state": "", "last_active": ""}
    d.update(kw)
    return d


def test_provably_dead_ausente_de_lista_nao_vazia():
    other = _sess(id="s1", name="oracle-wa", template="oracle-wa", state="active")
    assert claimant_provably_dead("gastown.dog", [other]) is True


def test_provably_dead_falso_com_template_vivo():
    live = _sess(id="d1", template="gastown.dog", state="active")
    assert claimant_provably_dead("gastown.dog", [live]) is False


def test_provably_dead_verdadeiro_so_com_estado_morto():
    dead = _sess(id="d2", template="gastown.dog", state="asleep")
    assert claimant_provably_dead("gastown.dog", [dead]) is True


def test_provably_dead_falso_com_estado_desconhecido_ambiguo():
    unknown = _sess(id="d1", template="gastown.dog", state="booting")
    assert claimant_provably_dead("gastown.dog", [unknown]) is False


def test_provably_dead_falso_quando_vivo_mas_quieto_zumbi():
    """ga-64usm: vivo-mas-parado NÃO é prova de morte — mantém a histerese."""
    stale_live = _sess(id="d1", template="gastown.dog", state="active",
                        last_active="2020-01-01T00:00:00Z")
    assert claimant_provably_dead("gastown.dog", [stale_live]) is False


def test_provably_dead_falso_com_lista_vazia():
    assert claimant_provably_dead("gastown.dog", []) is False
    assert claimant_provably_dead("gastown.dog", None) is False


def test_provably_dead_falso_para_coordenador():
    other = _sess(id="s1", name="oracle-wa", template="oracle-wa", state="active")
    assert claimant_provably_dead("gastown.mayor", [other]) is False


def test_provably_dead_match_concreto_por_identificador():
    dead = _sess(session_name="wa-worker-adhoc-x", agent_name="wa-worker-adhoc-x",
                  template="wa-worker", state="closed")
    assert claimant_provably_dead("wa-worker-adhoc-x", [dead]) is True


def test_provably_dead_falso_com_assignee_vazio():
    other = _sess(id="s1", name="oracle-wa", template="oracle-wa", state="active")
    assert claimant_provably_dead("", [other]) is False


def test_provably_dead_um_vivo_um_morto_vence_o_vivo():
    dead = _sess(id="d2", template="gastown.dog", state="asleep")
    live = _sess(id="d1", template="gastown.dog", state="active")
    assert claimant_provably_dead("gastown.dog", [dead, live]) is False


# ── session_owner_is_healthy: ALIVE != WORKING (ga-64usm / ga-nlaa) ──────────

def test_stale_activity_ttl_e_1800():
    """Pina o VALOR exato, não só a presença do nome. packs/town-deltas/assets/
    inflight-reclaim-guard.selftest.sh's check_pattern só grepa o guard-script
    consumidor (scripts/inflight-reclaim-guard.py) — desde que STALE_ACTIVITY_TTL
    migrou pra cá (ga-x3e7p), aquele arquivo só IMPORTA o nome, não atribui o
    valor, então o regex antigo (STALE_ACTIVITY_TTL\\s*=\\s*1800) não bate mais
    lá por desenho. O selftest.sh foi ajustado pra checar só a presença do nome,
    com um comentário dizendo que a correção do VALOR agora é responsabilidade
    deste arquivo — este teste é essa responsabilidade, cumprida. Os testes de
    session_owner_is_healthy abaixo usam idades hardcoded (60, 9999) que
    passariam pra qualquer TTL num range largo — não substituem esta asserção
    exata sobre a constante de 30min (ga-64usm) que gate reclaim/zumbi depende."""
    assert STALE_ACTIVITY_TTL == 1800


def test_healthy_falso_se_nao_bateu_sessao_viva():
    assert session_owner_is_healthy(False, 10, 10) is False


def test_healthy_conservador_sem_timestamp():
    assert session_owner_is_healthy(True, None, None) is True


def test_healthy_atividade_recente():
    assert session_owner_is_healthy(True, 60, None) is True


def test_healthy_atividade_velha_mas_bead_update_recente():
    assert session_owner_is_healthy(True, 9999, 60) is True


def test_healthy_falso_quando_tudo_stale_sem_isencao():
    assert session_owner_is_healthy(True, 9999, 9999) is False


def test_healthy_isencao_por_espera_humana():
    """ga-nlaa: parado num AskUserQuestion produz a MESMA telemetria de zumbi
    congelado — só conta como saudável com confirmação explícita do caller."""
    assert session_owner_is_healthy(True, 9999, 9999, awaiting_human_input=True) is True


def test_ephemeral_pool_templates_conhece_gastown_dog_e_wa_worker():
    assert "gastown.dog" in EPHEMERAL_POOL_TEMPLATES
    assert "wa-worker" in EPHEMERAL_POOL_TEMPLATES


def test_is_coordinator_pega_mayor_e_deacon():
    assert is_coordinator("gastown.mayor") is True
    assert is_coordinator("hq-deacon") is True
    assert is_coordinator("mila-wa") is False
    assert is_coordinator("") is False


def test_is_coordinator_case_insensitive_mixed_case():
    """Regressão (ga-x3e7p GATE-FAIL attempt 2/3, achado pelo reviewer +
    confirmado pelo Mayor): a consolidação inicial perdeu o .lower() que
    inflight-reclaim-guard.py's cópia original tinha (case-insensitive, por
    docstring). Sem ele, um identity 'Mayor'/'DEACON' deixaria de ser
    reconhecido como coordenador — perdendo proteção contra reclaim em 4
    call sites CORRECTNESS-CRITICAL do guard. FALHA no tip pré-fix, passa
    depois do .lower() restaurado."""
    assert is_coordinator("Gastown.Mayor") is True
    assert is_coordinator("HQ-DEACON") is True
    assert is_coordinator("MAYOR") is True


# ── pilot:held-until expira (ga-fup3m, absorvido de pilot-missing-route-watchdog.sh) ──
# scripts/pilot-missing-route-watchdog.sh (81 refs) já mede isto — seus próprios
# Scenario 7/8 de selftest provam o comportamento certo: pilot:held bare SEM
# held-until pareka indefinidamente; COM held-until EXPIRADO, não pareka mais.
# bead_state.py tratava QUALQUER held-until como park permanente — nunca checava
# se o timestamp já tinha passado. pilot:held / pilot:held-until:<epoch> são
# escritos JUNTOS por _mayor_deferred_hold_db (achado por ga-7qsxr, comentário do
# seu commit a2ac5c8c5).

def test_pilot_held_sem_held_until_pareka_indefinidamente():
    """Regressão-guarda: sem held-until, pilot:held bare continua parkeando
    (mirrors pilot-missing-route-watchdog.sh Scenario 7)."""
    st = derive(b(labels=["pilot:held"]), None, CREWS)
    assert st["state"] == "parked"


def test_pilot_held_until_expirado_nao_pareka_mais():
    """O achado real: held-until no PASSADO destrava (mirrors
    pilot-missing-route-watchdog.sh Scenario 8 exatamente)."""
    st = derive(b(labels=["pilot:held", "pilot:held-until:1000000000"]), None, CREWS, now=2000000000)
    assert st["state"] != "parked"


def test_pilot_held_until_futuro_continua_parkeando():
    st = derive(b(labels=["pilot:held", "pilot:held-until:2000000000"]), None, CREWS, now=1000000000)
    assert st["state"] == "parked"


def test_pilot_held_until_sem_now_preserva_comportamento_antigo():
    """now=None (não consultado) NUNCA expira um hold — mesma direção segura de
    todo outro None neste módulo. Todo chamador EXISTENTE (que não passa now)
    continua vendo o comportamento de HOJE, sem quebra."""
    st = derive(b(labels=["pilot:held", "pilot:held-until:1000000000"]), None, CREWS)
    assert st["state"] == "parked"


def test_pilot_held_expirado_mas_outro_motivo_de_park_independente_ainda_pareka():
    """Um hold expirado não pode mascarar outro motivo de park genuinamente
    independente na mesma bead."""
    st = derive(b(labels=["pilot:held", "pilot:held-until:1000000000", "blocked:outra-coisa"]),
                None, CREWS, now=2000000000)
    assert st["state"] == "parked"
    assert st["reasons"]["despausar"] == "parkeado por blocked:outra-coisa"


def test_pilot_held_multiplos_held_until_usa_o_maximo():
    """Mirrors a lógica 'max(held-until) < now' do arquivo-fonte: com dois
    held-until, só expira quando o MAIOR também já passou."""
    st = derive(b(labels=["pilot:held", "pilot:held-until:1000000000", "pilot:held-until:3000000000"]),
                None, CREWS, now=2000000000)
    assert st["state"] == "parked"   # o maior (3000000000) ainda não passou


# ── gate_active resolvido por marker (ga-zltsr) ─────────────────────────────────
# GATE_ACTIVE (regra 6) checava só os labels da própria bead — diferente de TODO
# outro consumidor de produção de estado-de-gate (pilot-dispatcher.sh's
# _filter_built, imparavel-check.py's classify_bead, painel_visibilidade.py pós
# ga-opzlf), que já sabem que o label pode ficar STALE: gate:queued é escrito na
# criação do marker e quase nunca limpo pelo pipeline principal (só 2 call sites de
# remoção na cidade inteira, contra 12 de gate:reviewing) — casos reais medidos:
# wa-nh37r e ga-tje7u carregaram gate:queued por DIAS depois do marker fechar.

def test_gate_active_none_preserva_heuristico_de_label_de_sempre():
    """gate_active=None (não resolvido) é o comportamento de TODO chamador
    existente hoje — nenhum passa este parâmetro ainda. Não pode mudar nada."""
    st = derive(b(labels=["gate:queued"]), None, CREWS)
    assert st["state"] == "at_gate"


def test_gate_active_false_destrava_apesar_do_label_residual():
    """O achado real: gate:queued sobrevive ao marker fechar. Quando o chamador
    CONSULTOU o marker (ex.: list_gate_active_source_beads()) e não achou nada
    ativo, isso GANHA do label — mirrors wa-nh37r/ga-tje7u."""
    st = derive(b(labels=["gate:queued"]), None, CREWS, gate_active=False)
    assert st["state"] == "backlog"   # cai pro heurístico normal, não trava em at_gate


def test_gate_active_true_conta_mesmo_sem_o_label_sincronizado():
    """Simétrico: um marker recém-criado pode existir antes do label ser escrito
    (ga-cxzby race) ou sem gate-status:* correspondente (wa-aogpc). O veredito do
    chamador GANHA nesta direção também."""
    st = derive(b(labels=[]), None, CREWS, gate_active=True)
    assert st["state"] == "at_gate"
