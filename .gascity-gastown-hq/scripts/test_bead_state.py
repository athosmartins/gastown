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
from bead_state import derive, holder_is_alive, is_athos_page, is_ephemeral, is_coordinator  # noqa: E402

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
