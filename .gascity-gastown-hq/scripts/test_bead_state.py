#!/usr/bin/env python3
"""Testes de bead_state.py — a derivação canônica de estado da cidade.

Cada teste aqui corresponde a um erro REAL medido, não a um caso imaginado. Um
módulo do qual 10 consumidores vão depender não pode ter o seu comportamento
definido só pelo primeiro que o leu.

    python3 -m pytest scripts/test_bead_state.py -q
"""
import sys
import os
import json
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bead_state import (  # noqa: E402
    derive, holder_is_alive, is_athos_page, is_ephemeral, is_needs_human,
    claimant_provably_dead, session_owner_is_healthy, session_activity_age,
    parse_iso_epoch, is_coordinator, is_active_owner, is_live_builder,
    EPHEMERAL_POOL_TEMPLATES,
    STALE_ACTIVITY_TTL,
)

BEAD_STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bead_state.py")

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


# ── has_active_branch: branch git ativo protege contra stranded (Decisão 3,
# ga-yy9td, fatia 3/6) ────────────────────────────────────────────────────────
# Porta o atalho que _sling_is_live já usa em bash (branch existente = prova de
# vida suficiente por si só, linha ~3386 de pilot-dispatcher.sh) — não é
# proteção nova. Decisão 4, item 2: testado como `is True`, nunca truthiness.

def test_in_progress_morto_mas_com_branch_ativo_nao_e_stranded():
    """O caso que este slice porta: detentor provadamente morto (alive is
    False), mas o chamador resolveu has_active_branch=True (via
    _target_has_real_branch/equivalente) — o branch prova trabalho em
    andamento mesmo sem sessão viva."""
    st = derive(b(status="in_progress", assignee="mila-wa"), frozenset(), CREWS,
                has_active_branch=True)
    assert st["state"] == "executing"
    assert "liberar_para_pool" not in st["actions"]


def test_in_progress_morto_com_branch_false_continua_stranded():
    """Regressão: has_active_branch=False (resolvido, sem branch) NÃO pode
    proteger — só True explícito ativa o atalho. Confirma que o novo
    parâmetro não afrouxou o caso já coberto por
    test_in_progress_com_prova_de_morte_e_stranded."""
    st = derive(b(status="in_progress", assignee="mila-wa"), frozenset(), CREWS,
                has_active_branch=False)
    assert st["state"] == "stranded"


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


# ── is_active_owner: idle-aware session records (ga-rwgp8, derive() swap fatia
# 2/6 — decisões 1+2 de docs/pilot-dispatcher-derive-swap-decisions.md). Porta
# 1:1 a regra jq verificada na fonte (pilot-dispatcher.sh's _ACTIVE_OWNER_IDS,
# linhas ~3383-3388): select(.state != "asleep") | select((.idle_minutes ==
# null) or (.idle_minutes < $thresh)). Thin wrapper sobre holder_is_alive —
# cada caso abaixo espelha um ramo real dessa regra, ou o bug ga-46wq5 que ela
# existe pra prevenir (dono idle/asleep sendo tratado como ativo, silenciando
# o dispatch queue).

def test_active_owner_nao_consultei_e_none():
    assert is_active_owner("mila-wa", None) is None


def test_active_owner_sem_match_e_false():
    assert is_active_owner("mila-wa", {}) is False
    assert is_active_owner(
        "mila-wa", {"oracle-wa-x1": {"state": "active", "idle_minutes": 5}}
    ) is False


def test_active_owner_coordenador_e_none_nao_false():
    """Herdado de holder_is_alive por composição, não reinventado: mayor/deacon
    nunca tem vivacidade CONFIRMADA, mesmo com registro de sessão presente."""
    assert is_active_owner(
        "mayor", {"gastown.mayor": {"state": "active", "idle_minutes": 0}}
    ) is None


def test_active_owner_idle_desconhecido_em_sessao_nao_asleep_e_ativo():
    """A regressão ga-46wq5, metade 1: idle_minutes=None numa sessão viva e
    NÃO-asleep (o caso comum: worker -adhoc- recém-criado que nunca populou
    last_active) resolve pra ATIVO — mass-reclamar esse trabalho nunca foi o
    que ga-46wq5 pediu (mirrors o comentário da fonte bash, linha ~3396: 'most
    unknowns are fresh -adhoc- pool workers... mass-reclaiming their beads was
    never what ga-46wq5 asked for')."""
    live = {"ps-mrfb-adhoc-x1": {"state": "active", "idle_minutes": None}}
    assert is_active_owner("ps-mrfb-adhoc-x1", live) is True


def test_active_owner_sentinela_zero_do_go_sessao_asleep_nao_e_ativo():
    """A regressão ga-46wq5, metade 2 (o fixture original do bug: 'sessão está
    asleep... é despachado'). Uma sessão asleep tem last_active == sentinela
    zero do Go ('0001-01-01T00:00:00Z'), que o CHAMADOR (bash,
    _SESSIONS_IDLE_JSON) já traduz pra idle_minutes=None antes de chegar
    aqui — idêntico em idle_minutes ao caso acima, mas com state='asleep'. Um
    check só de idle_minutes NUNCA distinguiria os dois (ambos None); é o
    check de state que protege, rodando ANTES do de idle_minutes, de
    propósito. Sem ele, o dono asleep pareceria ativo pra sempre e o bead
    nunca seria readmitido à fila de dispatch."""
    asleep = {"ps-mrfb-adhoc-x1": {"state": "asleep", "idle_minutes": None}}
    assert is_active_owner("ps-mrfb-adhoc-x1", asleep) is False


def test_active_owner_idle_abaixo_do_threshold_e_ativo():
    live = {"mila-wa-x1": {"state": "active", "idle_minutes": 10}}
    assert is_active_owner("mila-wa", live, idle_threshold_min=180) is True


def test_active_owner_idle_igual_ou_acima_do_threshold_nao_e_ativo():
    """>= threshold, não só >: mirrors a comparação estrita `idle_minutes <
    $thresh` da fonte — no limiar exato, já NÃO é ativo."""
    at_thresh = {"mila-wa-x1": {"state": "active", "idle_minutes": 180}}
    over_thresh = {"mila-wa-x1": {"state": "active", "idle_minutes": 999}}
    assert is_active_owner("mila-wa", at_thresh, idle_threshold_min=180) is False
    assert is_active_owner("mila-wa", over_thresh, idle_threshold_min=180) is False


def test_active_owner_threshold_customizado_nao_hardcoded():
    """O caller continua dono do valor real (PILOT_ASSIGNEE_IDLE_MINUTES) —
    bead_state.py não hardcoda 180 uma segunda vez, só espelha o default pra
    paridade (docs/pilot-dispatcher-derive-swap-decisions.md, Decisão 2)."""
    live = {"mila-wa-x1": {"state": "active", "idle_minutes": 50}}
    assert is_active_owner("mila-wa", live, idle_threshold_min=30) is False
    assert is_active_owner("mila-wa", live, idle_threshold_min=60) is True


def test_active_owner_casa_por_sufixo_como_holder_is_alive():
    """Mesma primitiva de casamento de holder_is_alive (Decisão 1) — o achado
    original de sufixo (crew 'mila-wa' vs sessão 'mila-wa-awispm94omdp') vale
    igual aqui, não é uma segunda reimplementação com um bug diferente."""
    live = {"mila-wa-awispm94omdp": {"state": "active", "idle_minutes": 5}}
    assert is_active_owner("mila-wa", live) is True


def test_active_owner_aceita_forma_antiga_set_sem_registro_rico():
    """Backward-compat explícito (Decisão 1): um chamador que só tem a forma
    antiga (set de identificadores, sem state/idle_minutes) ainda funciona —
    degrada pra 'sem dado extra, então não restringe' (mesma direção segura de
    idle_minutes=None), nunca lança exceção nem quebra."""
    assert is_active_owner("mila-wa", frozenset({"mila-wa-x1"})) is True
    assert is_active_owner("mila-wa", frozenset()) is False


def test_active_owner_registro_ausente_ou_none_para_match_nao_quebra():
    """Defensivo: um dict rico onde o registro de UM match é vazio/None (dado
    malformado de um chamador) não lança AttributeError — trata como 'sem
    dado extra', mesma direção segura de idle_minutes=None acima."""
    assert is_active_owner("mila-wa", {"mila-wa-x1": {}}) is True
    assert is_active_owner("mila-wa", {"mila-wa-x1": None}) is True


def test_live_builder_nao_consultei_e_none():
    assert is_live_builder("ps-worker-adhoc-x1", None) is None


def test_live_builder_sem_match_e_false():
    assert is_live_builder("ps-worker-adhoc-x1", {}) is False


def test_live_builder_coordenador_e_none_nao_false():
    """Herdado de holder_is_alive por composição (mesma disciplina de
    is_active_owner) — nunca chega no check '-adhoc-' porque holder_is_alive
    já retornou None antes."""
    assert is_live_builder(
        "mayor", {"gastown.mayor": {"state": "active", "idle_minutes": 0}}
    ) is None


def test_live_builder_nao_adhoc_asleep_ainda_e_vivo():
    """O oposto de is_active_owner de propósito (Decisão 1 do design doc): um
    crew NOMEADO/não-adhoc asleep ainda é dono do bead — o caminho de REUSE
    do dispatch (gt-4st3n) acorda ele deliberadamente. Só workers -adhoc- têm
    a regra 'asleep = morto'."""
    asleep_named = {"thies-wa": {"state": "asleep", "idle_minutes": None}}
    assert is_live_builder("thies-wa", asleep_named) is True


def test_live_builder_adhoc_asleep_e_false():
    """A regressão ga-mrfb: um worker …-adhoc… que foi pra asleep já deu
    drain-ack (wake_mode=fresh) e nunca retoma o build — tratá-lo como vivo
    prende o bead (NEVERSTARTED) e segura o slot da pool falsamente."""
    asleep_adhoc = {
        "ps-worker-adhoc-b942bd1523": {"state": "asleep", "idle_minutes": None}
    }
    assert is_live_builder("ps-worker-adhoc-b942bd1523", asleep_adhoc) is False


def test_live_builder_adhoc_acordado_e_vivo():
    awake_adhoc = {
        "ps-worker-adhoc-AWAKE01": {"state": "active", "idle_minutes": None}
    }
    assert is_live_builder("ps-worker-adhoc-AWAKE01", awake_adhoc) is True


def test_live_builder_casa_por_sufixo_como_holder_is_alive():
    """Mesma primitiva de casamento de holder_is_alive/is_active_owner
    (Decisão 1) — sem uma terceira reimplementação com um bug diferente."""
    live = {"mila-wa-awispm94omdp": {"state": "active", "idle_minutes": 5}}
    assert is_live_builder("mila-wa", live) is True


def test_live_builder_aceita_forma_antiga_set_sem_registro_rico():
    """Backward-compat explícito (Decisão 1): a forma antiga (set de
    identificadores, sem state) ainda funciona — sem registro rico, o check
    '-adhoc-'+asleep não pode confirmar 'asleep', então degrada pra
    ativo/vivo (mesma direção segura de is_active_owner's fallback), nunca
    lança exceção."""
    assert is_live_builder(
        "ps-worker-adhoc-x1", frozenset({"ps-worker-adhoc-x1"})
    ) is True
    assert is_live_builder("ps-worker-adhoc-x1", frozenset()) is False


def test_live_builder_registro_ausente_ou_none_para_match_nao_quebra():
    """Defensivo: um registro vazio/None pro match não lança AttributeError —
    mesma proteção de is_active_owner, aqui aplicada ao check de state."""
    assert is_live_builder("ps-worker-adhoc-x1", {"ps-worker-adhoc-x1": {}}) is True
    assert is_live_builder("ps-worker-adhoc-x1", {"ps-worker-adhoc-x1": None}) is True


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


def test_is_needs_human_reconhece_sufixo_hifen():
    """Regressão (ga-x3e7p GATE-FAIL attempt 3/3): a versão ORIGINAL de
    inflight-reclaim-guard.py's _has_needs_human_label (pré-migração) só
    reconhecia exato ou sufixo ":" — nunca "-". is_needs_human() (via
    park_labels.label_matches) reconhece os três. Verificado empiricamente
    contra o merge-base: _has_needs_human_label(["needs-human-followup"]) ==
    False lá, is_needs_human(["needs-human-followup"]) == True aqui. Label
    real, não hipotética (ga-3lsy1, bugs/tech-debt) — este é o teste que
    faltava exatamente no ponto onde o guarda diverge do comportamento
    antigo, achado pelo reviewer, não descoberto sozinho."""
    assert is_needs_human(["needs-human-followup"]) is True
    assert is_needs_human(["gate:needs-human-mayor-fixing"]) is True


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


# ── session_owner_is_healthy: session_multi_assigned (ga-zbrbt) ─────────────
# Duplo-despacho medido: uma sessão VIVA e genuinamente produzindo, mas
# trabalhando uma bead IRMÃ, validava QUALQUER bead da qual fosse assignee —
# o last_active fresco da sessão não prova que o trabalho é PARA ESTA bead.
# Medido: wa-jts45 ficou refém 344min (TTL de reclaim é 25) porque o guard via
# "sessão viva" e nunca chegava a checar evidência por-bead. Ver bead ga-zbrbt.

def test_healthy_multi_assigned_sem_evidencia_por_bead_nao_e_mais_saudavel():
    """Sessão viva+fresca, mas dona de 2+ beads in-flight ao mesmo tempo: a
    atividade fresca pode pertencer à bead IRMÃ, não a esta. Sem bd-update
    recente NESTA bead, session-level activity sozinho não basta mais."""
    assert session_owner_is_healthy(True, 60, None, session_multi_assigned=True) is False


def test_healthy_multi_assigned_mas_bead_update_recente_resgata():
    """Mesmo cenário de duplo-despacho, mas ESTA bead tem evidência própria
    (bd update recente) — a exigência por-bead está satisfeita, segue saudável."""
    assert session_owner_is_healthy(True, 60, 60, session_multi_assigned=True) is True


def test_healthy_multi_assigned_default_preserva_comportamento_anterior():
    """Default (session_multi_assigned=False) não muda nenhum caller
    pré-existente — nenhum dos 4 consumidores de session_owner_is_healthy
    passa este parâmetro ainda, e todos devem continuar exatamente como antes."""
    assert session_owner_is_healthy(True, 60, None) is True
    assert session_owner_is_healthy(True, 9999, 9999) is False


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

# ── CLI export de vocabulário (ga-8mzgn) ────────────────────────────────────
# Consumidores shell (pilot-missing-route-watchdog.sh e outros) hardcodam uma
# CÓPIA das listas de park deste módulo em jq — a mesma doença que motivou
# bead_state.py inteiro, um nível abaixo. `--export-vocab` deixa um consumidor
# shell VERIFICAR (não substituir) a própria cópia contra a fonte canônica, sem
# precisar rodar derive() em bash — não existe ponte bash->python nesta cidade
# (achado por ga-7qsxr/ga-4oc2k para pilot-dispatcher.sh, reconfirmado por
# ga-fup3m/ga-8mzgn para pilot-missing-route-watchdog.sh).

def _run_export_vocab():
    r = subprocess.run([sys.executable, BEAD_STATE_PATH, "--export-vocab"],
                        capture_output=True, text=True, timeout=10)
    return r


def test_export_vocab_saida_e_json_com_as_duas_listas():
    r = _run_export_vocab()
    assert r.returncode == 0, r.stderr
    data = json.loads(r.stdout)
    assert "PARK_PREFIXES" in data
    assert "PARK_EXACT" in data
    assert isinstance(data["PARK_PREFIXES"], list)
    assert isinstance(data["PARK_EXACT"], list)


def test_export_vocab_contem_os_prefixos_que_pilot_missing_route_watchdog_hardcoda():
    """As entradas específicas que pilot-missing-route-watchdog.sh's próprio jq
    filter hardcoda hoje (needs:engine-window, no-auto-dispatch,
    pilot:no-auto-dispatch, blocked:/blocked-on:/blocked-by:) devem seguir
    presentes na fonte canônica — se sumirem daqui sem o consumidor ser
    atualizado, o selftest do consumidor (Scenario de drift-check, ga-8mzgn)
    precisa pegar isso, não descobrir em produção."""
    r = _run_export_vocab()
    data = json.loads(r.stdout)
    all_vocab = set(data["PARK_PREFIXES"]) | set(data["PARK_EXACT"])
    for expected in ("needs:engine-window", "no-auto-dispatch", "pilot:no-auto-dispatch",
                      "blocked:", "blocked-on:", "blocked-by:", "framework:engine"):
        assert expected in all_vocab, f"'{expected}' desapareceu do vocabulário canônico"


def test_export_vocab_flag_desconhecida_falha_alto_e_claro():
    r = subprocess.run([sys.executable, BEAD_STATE_PATH, "--not-a-real-flag"],
                        capture_output=True, text=True, timeout=10)
    assert r.returncode != 0


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


# ── ga-98inr: vocabulário absorvido de park_labels.py (2026-07-20, ga-hzt8s) ──
# throughput-stall-watchdog.py já delegava a park_labels.py — um SEGUNDO módulo
# "canônico" que bead_state.py não conhecia. Cada caso abaixo corresponde a um
# label medido na população viva (candidatos story:approved/ctx:ready, 09/08)
# que ficava sem classificação de park neste módulo.

def test_needs_label_review_e_parked():
    """10 ocorrências na população viva (ex.: wa-5b6yw, sem outro label de freio)."""
    assert derive(b(labels=["ctx:ready", "needs-label-review"]), None, CREWS)["state"] == "parked"


def test_story_needs_human_e_parked():
    assert derive(b(labels=["story:approved", "story:needs-human"]), None, CREWS)["state"] == "parked"


def test_gate_needs_human_bare_e_variantes_nao_product_sao_parked():
    """gate:needs-human (bare, 3 ocorrências) e :technical (2 ocorrências, ex.
    wa-zy1ah) não batem em PARK_PREFIXES/PARK_EXACT nem em is_athos_page (só
    ':product' é vez do Athos) — caíam sem classificação nenhuma."""
    assert derive(b(labels=["ctx:ready", "gate:needs-human"]), None, CREWS)["state"] == "parked"
    assert derive(b(labels=["ctx:ready", "gate:needs-human:technical"]), None, CREWS)["state"] == "parked"
    assert derive(b(labels=["ctx:ready", "gate:needs-human:branch-content-mismatch"]),
                   None, CREWS)["state"] == "parked"


def test_gate_needs_human_product_continua_vez_do_athos():
    """Regressão: a nova entrada em PARK_PREFIXES não pode roubar a vez do Athos
    da variante ':product' — is_athos_page (branch 3) precisa continuar ganhando."""
    st = derive(b(labels=["ctx:ready", "gate:needs-human:product"]), None, CREWS)
    assert st["turn"] == "athos"
    assert st["state"] == "awaiting_athos"


def test_next_action_nao_athos_e_parked():
    """next-action:mayor (3), next-action:batista-constroi (2),
    next-action:oracle-constroi (1) — só next-action:athos tinha vocabulário."""
    for who in ("mayor", "batista-constroi", "oracle-constroi"):
        st = derive(b(labels=["ctx:ready", f"next-action:{who}"]), None, CREWS)
        assert st["state"] == "parked", (who, st)


def test_next_action_athos_continua_vez_do_athos():
    """Regressão: next-action:athos não pode virar 'parked' pela prefix nova."""
    st = derive(b(labels=["ctx:ready", "next-action:athos"]), None, CREWS)
    assert st["turn"] == "athos"


def test_next_action_in_progress_tambem_e_parked():
    """ga-1ygf6o: bead in_progress (não só status=open, que
    test_next_action_nao_athos_e_parked já cobria) também vira 'parked' com
    next-action:<alguém> — é o caso real: wa-u6ak0 ficou 76min 'em execução'
    pro painel/Pilot enquanto o crew esperava decisão do Mayor, porque nenhum
    label sinalizava a espera. A regra 4 (park) roda ANTES da regra 7
    (executing) independente de status — faltava só a prova de que isso vale
    também com in_progress, que é o status real do caso medido.

    ga-fwfcq6 (gate FAIL no attempt 1): turn é SEMPRE 'mayor' pra QUALQUER
    next-action:<x> — derive() não extrai <x>. O attempt 1 deste teste
    iterava 3 alvos mas só afirmava state=='parked', nunca turn, escondendo
    exatamente esse fato. Afirma turn=='mayor' pros 3 explicitamente agora,
    pra nenhuma doc conseguir reivindicar generalização que o código não tem
    sem quebrar este teste."""
    for who in ("mayor", "batista-constroi", "oracle-constroi"):
        st = derive(b(status="in_progress", labels=["ctx:ready", f"next-action:{who}"]),
                     None, CREWS)
        assert st["state"] == "parked", (who, st)
        assert st["turn"] == "mayor", (who, st)  # hoje SEMPRE mayor, nunca <who>


def test_next_action_athos_in_progress_continua_vez_do_athos():
    """Controle simétrico a test_next_action_athos_continua_vez_do_athos: o
    intercept de ATHOS_TURN (regra 3, roda antes do park) não pode regredir
    só porque o status é in_progress em vez de open."""
    st = derive(b(status="in_progress", labels=["next-action:athos"]), None, CREWS)
    assert st["turn"] == "athos", st
    assert st["state"] == "awaiting_athos", st


def test_waiting_on_e_parked():
    """3 ocorrências (waiting-on:external, :vespasiano-response, :wa-4e2m8)."""
    assert derive(b(labels=["story:approved", "waiting-on:external"]), None, CREWS)["state"] == "parked"


def test_reclaim_count_esgotado_e_parked():
    """CASO REAL: ga-6n9mq, ga-qpfza, ga-r7uec, ga-yd0k2 — pilot:reclaim-count:3
    SOZINHO (sem nenhum outro label de freio), cap=3 (mirrors park_labels.py's
    DEFAULT_RECLAIM_CAP). É um limiar NUMÉRICO — 'pilot:reclaim-count:3' como
    string exata pararia de bater no dia em que o cap mudasse (a mesma lição que
    ga-hzt8s já aprendeu para este exato padrão de label, só que em park_labels.py;
    bead_state.py não a herdou automaticamente)."""
    assert derive(b(labels=["story:approved", "pilot:reclaim-count:3"]), None, CREWS)["state"] == "parked"
    assert derive(b(labels=["story:approved", "pilot:reclaim-count:5"]), None, CREWS)["state"] == "parked"


def test_reclaim_count_abaixo_do_cap_nao_e_parked_por_isso():
    """19 ocorrências de pilot:reclaim-count:1 na população viva — não pode virar
    supressor geral. Regressão: abaixo do cap, isolado, backlog normal."""
    st = derive(b(status="open", labels=["ctx:ready", "exec:auto", "pilot:reclaim-count:1"]),
                None, CREWS)
    assert st["state"] != "parked"


def test_flowing_labels_batem_antes_de_armed():
    """CASO REAL AO VIVO (09/08): a própria ga-98inr — o bug que absorve este gap —
    carrega ctx:ready+exec:auto+story:approved+story:in-flight+pilot:dispatched.
    Sem este branch, ARMED (branch 10) venceria e devolveria 'ready': um bead JÁ
    despachado sendo reoferecido ao pool como backlog ocioso. Mesmo padrão medido
    em ga-fup3m e ga-x3e7p (as duas irmãs da mesma fatia)."""
    st = derive(b(status="open",
                  labels=["ctx:ready", "exec:auto", "story:approved",
                          "story:in-flight", "pilot:dispatched"]),
                None, CREWS)
    assert st["state"] == "flowing"
    assert st["state"] != "ready"


def test_flowing_cobre_os_4_labels_do_grupo():
    for label in ("story:in-flight", "pilot:dispatched", "pilot:dispatching", "story:done"):
        st = derive(b(status="open", labels=[label]), None, CREWS)
        assert st["state"] == "flowing", (label, st)


def test_armed_sem_flowing_continua_ready():
    """Regressão: o branch novo não pode engolir o caso comum (armado, roteado,
    sem nenhum label de 'já em movimento')."""
    st = derive(b(status="open", labels=["ctx:ready", "exec:auto"],
                  metadata={"gc.routed_to": "gastown.dog"}),
                None, CREWS)
    assert st["state"] == "ready"


# ── família "blocked" / "needs:rehome" (ga-98inr, gate_run=ga-wdl56 fix-attempt 2) ──
# Reviewer mediu, com as funções REAIS de _canonical_is_braked vs. o antigo
# _bead_is_braked (park_labels.label_matches: exato, ou sufixo ":"/"-"), que
# bead_state.py não era o superset assumido — estas 5 formas batiam no antigo
# check e não no canônico, silenciosamente ENCOLHENDO a exclusão de backlog.

def test_blocked_bare_e_parked():
    assert derive(b(labels=["story:approved", "blocked"]), None, CREWS)["state"] == "parked"


def test_blocked_on_e_parked():
    assert derive(b(labels=["story:approved", "blocked-on"]), None, CREWS)["state"] == "parked"


def test_blocked_on_external_e_parked():
    assert derive(b(labels=["story:approved", "blocked-on-external"]), None, CREWS)["state"] == "parked"


def test_blocked_reason_capacity_e_parked():
    assert derive(b(labels=["story:approved", "blocked-reason:capacity"]), None, CREWS)["state"] == "parked"


def test_needs_rehome_property_e_parked():
    """needs:rehome-property: label real citado por nome no docstring de
    _bead_is_braked em throughput-stall-watchdog.py — zero beads na população
    viva hoje (10/08), mas vocabulário documentado, não hipotético."""
    assert derive(b(labels=["story:approved", "needs:rehome-property"]), None, CREWS)["state"] == "parked"


def test_blocked_reason_decision_continua_vez_do_athos():
    """Regressão: a nova entrada bare 'blocked' em PARK_PREFIXES não pode roubar
    a vez do Athos de blocked-reason:decision — ATHOS_TURN (regra 3) roda ANTES
    da regra 4 (park) e precisa continuar ganhando."""
    st = derive(b(labels=["ctx:ready", "blocked-reason:decision"]), None, CREWS)
    assert st["turn"] == "athos"
    assert st["state"] == "awaiting_athos"


def test_story_blocked_prefixado_continua_sem_vocabulario():
    """Não-regressão deliberada: 'story:blocked' é EXACT (não prefixo) e formas
    sufixadas (story:blocked:x, story:blocked-x) não têm evidência real em código
    nem na população viva (medido 10/08) — ao contrário de 'blocked'/
    'needs:rehome', que o docstring de outros arquivos cita por nome. Este teste
    documenta o escopo, não um bug: widening especulativo sem evidência é o
    mesmo erro de forma oposta (over-match em vez de under-match)."""
    st = derive(b(labels=["story:approved", "story:blocked:algumacoisa"]), None, CREWS)
    assert st["state"] != "parked"


# ── parâmetro omitido == None explícito (Decisão 4, item 3 — ga-rwgp8) ───────
# "toda vez que um swap acidentalmente troca None por False silenciosamente,
# uma sessão viva vira reciclada" — este é o teste que pegaria isso ANTES de
# um call site real, não depois. Não testa a LÓGICA de cada regra (os testes
# acima já fazem isso); testa a OMISSÃO em si: para cada parâmetro opcional de
# derive(), chamar sem ele precisa devolver EXATAMENTE o mesmo dict que chamar
# com ele passado como None explícito — nenhum default silenciosamente
# diferente de None pode se infiltrar num parâmetro cujo contrato é tri-state.
# Cobre os 5 parâmetros opcionais de derive() hoje: live_sessions, known_crews
# (frozenset() é o default, não None — mas mesmo princípio: omitido ==
# default explícito), merged, now, gate_active, has_active_branch.

_OMITTED_PARAM_FIXTURES = (
    ("backlog_simples", b()),
    ("in_progress_com_assignee", b(status="in_progress", assignee="mila-wa")),
    ("gate_failed", b(status="open", labels=["gate:needs-fix"], assignee="mila-wa")),
    ("gate_queued", b(labels=["gate:queued"])),
    ("gate_passed_merged_none", b(labels=["gate:passed"])),
    ("armed_roteado", b(status="open", labels=["ctx:ready", "exec:auto"],
                         metadata={"gc.routed_to": "gastown.dog"})),
    ("pilot_held_com_until", b(labels=["pilot:held", "pilot:held-until:1000000000"])),
    ("exec_manual_sem_crew", b(labels=["exec:manual"])),
)


def test_derive_todos_parametros_omitidos_e_identico_a_todos_none_explicito():
    for nome, bead in _OMITTED_PARAM_FIXTURES:
        omitido = derive(bead)
        explicito = derive(bead, live_sessions=None, known_crews=frozenset(),
                            merged=None, now=None, gate_active=None,
                            has_active_branch=None)
        assert omitido == explicito, (nome, omitido, explicito)


def test_derive_live_sessions_omitido_e_identico_a_none_explicito():
    """Isolado do teste acima (que já cobre via kwargs completos) — este varia
    SÓ live_sessions, provando que especificamente ele não é o parâmetro que
    poderia divergir se um dia ganhasse um default diferente de None."""
    for nome, bead in _OMITTED_PARAM_FIXTURES:
        assert derive(bead) == derive(bead, None), nome


def test_derive_merged_omitido_e_identico_a_none_explicito():
    st_omitido = derive(b(labels=["gate:passed"]), None, CREWS)
    st_explicito = derive(b(labels=["gate:passed"]), None, CREWS, merged=None)
    assert st_omitido == st_explicito


def test_derive_now_omitido_e_identico_a_none_explicito():
    bead = b(labels=["pilot:held", "pilot:held-until:1000000000"])
    st_omitido = derive(bead, None, CREWS)
    st_explicito = derive(bead, None, CREWS, now=None)
    assert st_omitido == st_explicito


def test_derive_gate_active_omitido_e_identico_a_none_explicito():
    bead = b(labels=["gate:queued"])
    st_omitido = derive(bead, None, CREWS)
    st_explicito = derive(bead, None, CREWS, gate_active=None)
    assert st_omitido == st_explicito


def test_derive_has_active_branch_omitido_e_identico_a_none_explicito():
    bead = b(status="in_progress", assignee="mila-wa")
    st_omitido = derive(bead, frozenset(), CREWS)
    st_explicito = derive(bead, frozenset(), CREWS, has_active_branch=None)
    assert st_omitido == st_explicito
