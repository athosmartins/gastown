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
    "needs:engine-window", "pilot:held-until:",
    # gate:needs-human* (QUALQUER sufixo, incl. sem sufixo) — achado 09/08 catalogando
    # pilot-dispatcher.sh p/ ga-7qsxr (300 refs, o maior interpretador privado): é o
    # veto de park mais usado do arquivo (10+ call sites), confirmado por TRÊS leituras
    # independentes do mesmo arquivo. Só o sufixo :product já tinha lar aqui (via
    # is_athos_page/regra 3, que roda ANTES desta — logo :product continua indo pro
    # Athos; só as OUTRAS variantes — :technical, :mayor-fixing, :on-device, ou a forma
    # bare "gate:needs-human" — caem aqui). Sem isto, derive() dizia "ready"/"backlog"
    # pra uma bead que o Pilot nunca despacharia. Custo medido no arquivo-fonte:
    # ga-3lsy1 (dispatched 4x apesar do label desde a criação) e o TOCTOU re-check de
    # dispatch_one, cujo combined-regex não conhecia a forma bare e despachou 253s
    # depois de um hold explícito do Mayor.
    "gate:needs-human",
    "needs-human",   # bare, sem prefixo gate:/story: — usado p/ bugs/tech-debt (ga-3lsy1)
    "waiting-on:", "depends-on:",
    # ga-98inr: absorvido de park_labels.py (ga-hzt8s, 2026-07-20) — um SEGUNDO
    # módulo "canônico" que já consolidava 3 consumidores e que este módulo não
    # conhecia. Da lista original do park_labels.py, só "next-action:" era
    # genuinamente NOVA aqui — "gate:needs-human"/"needs:engine-window"/
    # "waiting-on:" já estavam cobertas acima (linhas 50/62/64), e "pilot:held"
    # (bare, como PREFIXO) foi DELIBERADAMENTE removida de novo durante o rebase
    # com ga-98inr (2026-08-10): reintroduzia exatamente a colisão com
    # pilot:held-count:<slug>:<n> que o comentário de PARK_EXACT abaixo já
    # documenta como "o achado mais urgente da sessão" (mergeado 884e8a670) —
    # como PREFIXO, "pilot:held" casa "pilot:held-count:..." também, prendendo
    # a bead em 'parked' pra sempre; como EXACT (única forma correta, já
    # presente em PARK_EXACT), casa só o label bare. "next-action:" leva ":"
    # porque toda ocorrência medida na população viva (09/08) era sufixada por
    # ":" — só next-action:athos é exceção, e ATHOS_TURN/branch 3 já intercepta
    # ela antes deste branch.
    "next-action:",
)
PARK_EXACT = frozenset({
    "framework:engine", "no-auto-dispatch", "pilot:no-auto-dispatch",
    "story:awaiting-external-merge", "on-device", "story:needs-device", "phone-proxy",
    # Achados 09/08 catalogando pilot-dispatcher.sh p/ ga-7qsxr — cada um tem pelo menos
    # um call site real no arquivo-fonte:
    "pilot:held",            # bare — movido de PARK_PREFIXES (era prefixo, e por ser
                              # prefixo colidia com o contador de bookkeeping
                              # pilot:held-count:<slug>:<n> de _pilot_hold_or_escalate,
                              # que NUNCA é limpo/decrementado. Sob o match antigo, uma
                              # bead segurada UMA VEZ ficava "parked" pra SEMPRE, mesmo
                              # muito depois de despachada/no-gate/mergeada — porque
                              # "parked" é checado (regra 4) antes de gate_failed/
                              # at_gate/executing (regras 5-7). Este é o achado mais
                              # urgente da sessão: já afeta o painel EM PRODUÇÃO (1º
                              # consumidor migrado, mergeado 884e8a670). O par legítimo
                              # pilot:held / pilot:held-until:<epoch> continua coberto
                              # (exact + prefixo, respectivamente); só o contador deixa
                              # de colidir.
    "story:blocked", "story:needs-human", "story:cancelled",
    "type:future", "cost-decision", "prod-experiment", "ban-risk",
    "engine-window:pending",  # distinto de needs:engine-window (Fase 2 batched
                               # deliberadamente, não bloqueada — nomes quase iguais,
                               # significados opostos)
    # ga-98inr: idem — 10 e 1 ocorrências medidas na população viva (09/08),
    # nenhuma das duas com forma sufixada observada.
    "needs-label-review", "story:needs-human",
})
# ga-98inr: pilot:reclaim-count:N é um LIMIAR NUMÉRICO, não um label a listar —
# a mesma lição que park_labels.py já pagou uma vez (ga-hzt8s comment: uma versão
# anterior deste vocabulário em OUTRO consumidor listava "pilot:reclaim-count:3"
# como string exata, e um cap alterado teria parado de bater silenciosamente).
# Mirrors park_labels.py's DEFAULT_RECLAIM_CAP — os dois não têm fonte única
# entre si (pré-existente, fora do escopo desta fatia; mesma ressalva que
# park_labels.py já documenta para MAX_RECLAIMS do inflight-reclaim-guard.py).
RECLAIM_CAP = 3
# ga-98inr: absorvido de park_labels.py's FLOWING_OR_DONE_LABELS. Um bead JÁ
# despachado ou finalizado não é backlog ocioso — mas também não é "parked"
# (que implica um bloqueio a resolver). CASO REAL AO VIVO (09/08): a própria
# ga-98inr (o bug que absorve este gap) carrega ctx:ready+exec:auto+
# story:approved+story:in-flight+pilot:dispatched — sem este vocabulário,
# ARMED (branch 10) venceria e devolveria "ready", reoferecendo ao pool um
# bead que já está sendo trabalhado. Mesmo padrão em ga-fup3m/ga-x3e7p.
FLOWING_LABELS = frozenset({
    "story:in-flight", "pilot:dispatched", "pilot:dispatching", "story:done",
})
# Estágios de refino: o bead ainda não é construível.
UNREFINED = frozenset({
    "ctx:thin", "story:unrefined", "story:epic",
    "story:refinement-in-progress", "refino:policy-gap", "refino:info-gap",
    "story:triage",  # agrupada com as 2 acima em pilot-dispatcher.sh's
                      # _FILTER_PREAPPROVAL_LABELS — mesma "guarda-chuva pré-aprovação"
                      # (achado 09/08, ga-7qsxr)
})
ARMED = frozenset({"ctx:ready", "exec:auto"})
GATE_ACTIVE = frozenset({"gate:queued", "gate:reviewing", "gate:needs-rebase"})
GATE_FAILED = frozenset({"gate:failed", "gate:needs-fix"})
ATHOS_TURN = frozenset({
    "story:needs-approval", "next-action:athos", "blocked-reason:decision",
    "refino:policy-gap",       # lacuna de POLÍTICA = decisão de produto, só ele decide
})
# Só a variante de DECISÃO DE PRODUTO do gate é dele. Técnica/roteamento/
# mayor-fixing/on-device são do Mayor/crew (ga-aprov, Athos: "rodar o máximo sem mim").
ATHOS_GATE_HUMAN_SUFFIXES = frozenset({"product"})
# ⚠️ story:refino-escalado / auto-refino:escalated NÃO estão aqui, DE PROPÓSITO.
# "O refino escalou" diz que o refinador desistiu — não diz que existe decisão do
# Athos. Sem uma classificação de lacuna (policy-gap = ele; info-gap = o criador),
# a escalação é NÃO-CLASSIFICADA: é triagem do Mayor. Medido 09/08: ga-n77jl, uma
# feature migrada do ClickUp com descrição completa e zero perguntas, ficou na
# coluna do Athos sem NENHUM botão possível — exatamente o sintoma que ele reportou
# ("estão na etapa 'sua vez' mas nenhuma tem um botão que as destrave"). A ação real
# ali era refinar/priorizar, que é trabalho do Mayor.


def is_athos_page(labels) -> bool:
    """True sse existe uma ação que SÓ o Athos pode tomar.

    Vocabulário absorvido de painel_visibilidade._has_athos_page_label, que já era
    mais preciso que a 1ª versão deste módulo. Convergir para o MELHOR dos dois é o
    ponto do modelo único — migrar cru teria REGREDIDO o painel.
    """
    lset = labels if isinstance(labels, (set, frozenset)) else set(labels or [])
    if lset & ATHOS_TURN:
        return True
    pfx = "gate:needs-human:"
    return any(str(l).startswith(pfx) and str(l)[len(pfx):] in ATHOS_GATE_HUMAN_SUFFIXES
               for l in lset)

EPHEMERAL_MARKERS = ("-adhoc-", "claude-headless", "wa-worker-", "ps-worker-", "dog-")
# Formas NUAS (sem sufixo à direita) dos mesmos templates de pool. "wa-worker" sozinho
# não bate "wa-worker-" (falta o traço final) e "gastown.dog" não bate "dog-" (idem) —
# então is_ephemeral() dizia False pras duas, enquanto pilot-dispatcher.sh já as tratava
# como efêmeras explicitamente (padrão bash `case`:
# gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*, 2 call sites).
# Achado 09/08 catalogando aquele arquivo p/ ga-7qsxr, confirmado por 2 leituras
# independentes. Sem isto, um crew_of() chamado com a forma nua resolveria como se
# fosse um crew real.
EPHEMERAL_EXACT = frozenset({"gastown.dog", "wa-worker", "ps-worker"})


def _labels(bead) -> frozenset:
    return frozenset(bead.get("labels") or [])


def _has_prefix(labels, prefixes) -> str | None:
    for l in labels:
        for p in prefixes:
            if l.startswith(p):
                return l
    return None


def _labels_after_expired_hold(labels, now):
    """labels, minus an EXPIRED pilot:held hold — ga-fup3m, absorvido de
    pilot-missing-route-watchdog.sh (81 refs, seus próprios Scenario 7/8).

    pilot:held (bare) e pilot:held-until:<epoch> são escritos JUNTOS por
    _mayor_deferred_hold_db (achado por ga-7qsxr). Sem held-until, o hold pareka
    indefinidamente (comportamento preservado). Com held-until, o hold só continua
    valendo enquanto o MAIOR timestamp presente ainda não passou — mirrors a lógica
    'max(held-until) < now' do arquivo-fonte exatamente. now=None (não consultado)
    NUNCA expira um hold, mesma direção segura que todo outro None neste módulo:
    todo chamador que não passa now preserva o comportamento de hoje (park
    indefinido), sem quebra.

    Qualquer OUTRO motivo de park que a bead carregue independentemente do hold
    continua no conjunto devolvido — só o par pilot:held/pilot:held-until é
    removido, nunca o resto."""
    if now is None:
        return labels
    until_values = []
    for l in labels:
        if l.startswith("pilot:held-until:"):
            suffix = l[len("pilot:held-until:"):]
            if suffix.isdigit():
                until_values.append(int(suffix))
    if not until_values or max(until_values) >= now:
        return labels
    return frozenset(l for l in labels if l != "pilot:held" and not l.startswith("pilot:held-until:"))


def _reclaim_exhausted(labels) -> bool:
    """True sse algum pilot:reclaim-count:N tem N >= RECLAIM_CAP — ga-98inr,
    mirrors park_labels.py's is_reclaim_exhausted/parse_reclaim_count."""
    best = 0
    for l in labels:
        if l.startswith("pilot:reclaim-count:"):
            try:
                best = max(best, int(l.rsplit(":", 1)[1]))
            except (ValueError, IndexError):
                pass
    return best >= RECLAIM_CAP


def is_ephemeral(actor: str) -> bool:
    """Worker efêmero NÃO é crew. Confundir os dois foi a causa do 'claude-wa'
    inexistente que quebrou o botão Cutucar (medido 09/08)."""
    if not actor:
        return False
    return actor in EPHEMERAL_EXACT or any(m in actor for m in EPHEMERAL_MARKERS)


def crew_of(actor: str, known_crews: frozenset) -> str | None:
    """Resolve um actor para um crew REAL, ou None. Valida contra a lista viva —
    nunca devolve nome derivado sem existência confirmada."""
    if not actor or is_ephemeral(actor):
        return None
    if actor in known_crews:
        return actor
    base = actor.split("-adhoc-")[0].split("-ga")[0]
    return base if base in known_crews else None


# ga-8lrud: absorvido de inflight-reclaim-guard.py's COORDINATOR_MARKERS/is_coordinator
# (scripts/inflight-reclaim-guard.py:289-294,1144-1152) — MESMO vocabulário, substring
# match, não prefixo/exato, de propósito (a guarda original já usa substring e vários
# consumidores já dependem dessa amplitude via reclaim_liveness.claimant_provably_dead).
# Papel sempre-ligado: nunca é candidato a "morto comprovado".
COORDINATOR_MARKERS = ("mayor", "deacon")


def is_coordinator(identity: str) -> bool:
    if not identity:
        return False
    return any(marker in identity for marker in COORDINATOR_MARKERS)


def holder_is_alive(assignee: str, live_sessions) -> bool | None:
    """O detentor do bead está vivo? True / False / None = NÃO DÁ PRA SABER.

    ⚠️ TRÊS ERROS MEDIDOS, todos produzindo "abandonado" com confiança sobre
    trabalho VIVO (ou, no 3º caso, sobre um papel que nunca "morre") — que é o
    pior falso-positivo que este módulo pode ter, porque a ação que ele autoriza
    é RECLAMAR o bead de quem está trabalhando nele.

    1. NOME COM SUFIXO. O assignee é o nome do crew (`mila-wa`); a sessão viva
       chama-se `mila-wa-awispm94omdp`. A comparação era `assignee in live_sessions`,
       igualdade exata — então para crew ela era praticamente SEMPRE falsa. Casamos
       agora por prefixo nos dois sentidos.
    2. FONTE INCOMPLETA. Montei a lista de vivos com `tmux -L gascity ls` e classifiquei
       como abandonado um gate-reviewer que estava VIVO fora do tmux (PID 34105,
       terminal s011). Uma fonte incompleta não devolve "não sei": devolve um veredito
       ERRADO. Por isso `live_sessions=None` agora significa NÃO CONSULTEI, é distinto
       de `frozenset()` = CONSULTEI E NÃO HÁ NINGUÉM, e só o segundo pode concluir
       "abandonado".
    3. COORDENADOR SEM PROTEÇÃO (ga-8lrud, absorvido de inflight-reclaim-guard.py's
       is_coordinator()/COORDINATOR_MARKERS). assignee="mayor"/"deacon" é um papel
       sempre-ligado, mas a sessão viva se chama "gastown.mayor"/"gastown.deacon" —
       um PREFIXO diferente do assignee bare, que o casamento por sufixo acima não
       cobre (nem `s==assignee`, nem `s.startswith(assignee+"-")`, nem o inverso).
       Sem esta guarda, um bead in_progress do mayor/deacon resolvia alive=False →
       "stranded", oferecendo liberar_para_pool sobre um papel que nunca deveria ser
       reclamado. R4 e R7 do lifecycle-coherence-janitor.sh já protegiam "mayor" à
       mão (exclusão hardcoded antes mesmo de qualquer checagem de liveness) — prova
       de que consumidores de produção já tinham aprendido essa lição; o modelo
       canônico não. Nenhum bead in_progress de mayor/deacon existia no momento da
       medição (09/08) — gap latente, não incidente vivo, mas real: qualquer
       consumidor futuro que confie cegamente em holder_is_alive()/derive() herdaria
       o mesmo buraco que a versão *hardcoded* já tinha fechado.

    ⭐ FONTE CANÔNICA DE VIVACIDADE — use esta, não invente a sua:
           gc session list --json      → 72 sessões (medido 09/08)
           tmux -L gascity ls          → 13  ⚠️ perde ~80% dos agentes
       Foi o tmux que me enganou. O inflight-reclaim-guard.py já usava
       `gc session list --json` e já tinha teste pra "consulta falhou → não reclama
       nada" (DD-7) — ele estava CERTO antes deste módulo existir.
       ⚠️ Caveat que aquele guard documenta e vale herdar: sessão pode ficar
       state=active produzindo zero saída (zumbi com quota estourada). VIVO ≠
       TRABALHANDO; para decisão de reclaim, vivacidade é condição necessária, não
       suficiente.
    """
    if live_sessions is None:
        return None
    if not assignee:
        return False
    if is_coordinator(assignee):
        # None, não True: nunca verificamos vivacidade de fato para um coordenador —
        # só recusamos concluir morte. Mesma semântica de live_sessions=None ("não
        # consultei"), e produz o mesmo resultado em todo call site de derive() hoje
        # (regra 7 só vira "stranded" com alive IS False; None e True são idênticos
        # ali) — sem fingir uma certeza que não temos.
        return None
    for s in live_sessions:
        if s == assignee or s.startswith(assignee + "-") or assignee.startswith(s + "-"):
            return True
    return False


def derive(bead: dict, live_sessions=None,
           known_crews: frozenset = frozenset(),
           merged: bool | None = None,
           now: int | None = None,
           gate_active: bool | None = None) -> dict:
    """Estado canônico. PURA — todo fato de runtime entra por parâmetro.

    live_sessions: conjunto de sessões vivas, ou None = NÃO CONSULTEI. None nunca
            vira "ninguém vivo" — ver holder_is_alive().
    merged: True/False se o chamador verificou o merge; None = não verificou.
            None NUNCA é tratado como False (erro ≠ vazio).
    now: epoch atual, ou None = não consultado. Usado só para expirar
            pilot:held-until:<epoch> (ga-fup3m) — ver _labels_after_expired_hold().
            None preserva o comportamento antigo (park indefinido), nunca expira.
    gate_active: True/False se o chamador já resolveu via lookup de marker
            (ex.: inflight-reclaim-guard.py's list_gate_active_source_beads() /
            lifecycle-coherence-janitor.sh's _gate_active_beads()); None = não
            resolvido, cai no heurístico de label (GATE_ACTIVE ∩ labels) — o
            comportamento de hoje, preservado para todo chamador que não passa
            este parâmetro (mesma convenção de `now`). Quando o chamador RESOLVE,
            o veredito dele GANHA do label nos dois sentidos: um marker fechado
            destrava mesmo com gate:queued residual (a lacuna que ga-zltsr
            documentou — a mesma doença que painel_visibilidade.py parou de
            confiar em gate:queued sozinho, ga-opzlf), e um marker aberto conta
            como at_gate mesmo se o label ainda não sincronizou.
    """
    L = _labels(bead)
    status = bead.get("status") or ""
    assignee = bead.get("assignee") or ""
    alive = holder_is_alive(assignee, live_sessions)
    holder_alive = alive is True
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

    # 3. VEZ DO ATHOS — só quando há ação que SÓ ele toma.
    # ⚠️ Vem ANTES do park DE PROPÓSITO. O contrato das colunas (Athos, 17/07) diz:
    # "um bead que precisa do Athos NUNCA pode estar em Travadas — é mis-filing". Um
    # bead com blocked:* E story:needs-approval é destravado pela decisão DELE, então
    # a decisão ganha do bloqueio. Com o park antes, ele sumia da coluna dele e ia
    # parar em Travadas, onde ninguém espera achar uma decisão pendente.
    if is_athos_page(L):
        offer("aprovar", True); offer("rejeitar", True)
        return {"state": "awaiting_athos", "turn": "athos", "actions": actions, "reasons": reasons}

    # 4. PARK EXPLÍCITO — decisão deliberada de não andar.
    park_labels = _labels_after_expired_hold(L, now)
    park = _has_prefix(park_labels, PARK_PREFIXES) or next((l for l in park_labels if l in PARK_EXACT), None)
    exhausted = _reclaim_exhausted(L)  # ga-98inr: limiar numérico, não label
    if park or exhausted or status == "deferred":
        ext = "story:awaiting-external-merge" in L or park == "blocked:external-quota-motherduck"
        motivo = park or (f"pilot:reclaim-count esgotado (>={RECLAIM_CAP})" if exhausted
                           else "status=deferred")
        return {"state": "parked", "turn": "external" if ext else "mayor",
                "actions": ["despausar"], "reasons": {"despausar": f"parkeado por {motivo}"}}

    # 5. GATE REPROVOU — vez de quem constrói, não do Athos.
    if L & GATE_FAILED:
        crew = crew_of(assignee, known_crews) or crew_of(bead.get("owner") or "", known_crews)
        offer("cutucar_crew", bool(crew), "nenhum crew real identificável (assignee é efêmero e owner não resolve)")
        # Só devolve pro pool com PROVA de que o detentor morreu. `alive is None`
        # (não consultei) NÃO autoriza: reclamar bead de quem está trabalhando nela
        # é o dano irreversível deste módulo.
        offer("devolver_pro_pool", alive is False,
              f"{assignee} está VIVO e trabalhando nesta bead" if alive
              else "vivacidade do detentor NÃO foi consultada — não dá pra afirmar que morreu")
        offer("regatear", False, "nada mudou no código desde a reprovação — re-gatear reprova igual")
        return {"state": "gate_failed", "turn": ("crew:" + crew) if crew else "mayor",
                "actions": actions, "reasons": reasons}

    # 6. NO GATE — gate_active resolvido pelo chamador GANHA do label; None cai no
    # heurístico de label de sempre (ver docstring de derive()).
    at_gate = (L & GATE_ACTIVE) if gate_active is None else gate_active
    if at_gate:
        return {"state": "at_gate", "turn": "nobody", "actions": [], "reasons": {}}

    # 7. EM EXECUÇÃO — 'stranded' exige PROVA de que o detentor morreu.
    # `alive is None` (não consultei) resolve para 'executing', não para 'stranded':
    # o default seguro é presumir que o trabalho está vivo, porque a ação que
    # 'stranded' autoriza é tirar o bead de quem o segura.
    if status == "in_progress":
        if alive is not False:
            return {"state": "executing", "turn": "crew:" + (crew_of(assignee, known_crews) or assignee or "?"),
                    "actions": ["cutucar"],
                    "reasons": {} if alive else {
                        "_incerteza": "vivacidade não consultada — 'executando' é o default seguro"}}
        return {"state": "stranded", "turn": "mayor",
                "actions": ["liberar_para_pool"],
                "reasons": {}}

    # 8. NÃO REFINADO
    if L & UNREFINED:
        return {"state": "unrefined", "turn": "mayor", "actions": ["refinar"], "reasons": {}}

    # 9. JÁ EM MOVIMENTO — ga-98inr. Despachado ou finalizado; não é backlog
    # ocioso, mas também não é 'parked' (que implica bloqueio a resolver).
    # Vem ANTES de exec:manual/ARMED de propósito: um bead pode carregar
    # ctx:ready+exec:auto (labels que sobrevivem ao despacho) e AINDA assim já
    # estar em voo — checar ARMED primeiro reofereceria ao pool um bead que já
    # está sendo trabalhado (ver FLOWING_LABELS acima para o caso real medido).
    if L & FLOWING_LABELS:
        crew = crew_of(assignee, known_crews)
        return {"state": "flowing", "turn": ("crew:" + crew) if crew else "pool",
                "actions": [], "reasons": {}}

    # 10. exec:manual — o balde. O executor DEFINE de quem é a vez.
    if "exec:manual" in L:
        crew = crew_of(assignee, known_crews)
        if crew:
            return {"state": "manual_assigned", "turn": "crew:" + crew, "actions": ["cutucar"], "reasons": {}}
        # ⭐ SEM EXECUTOR: vai pra TRIAGEM DO MAYOR, nunca pro Athos.
        return {"state": "manual_unrouted", "turn": "mayor",
                "actions": ["nomear_executor"],
                "reasons": {"_diagnostico": "exec:manual sem executor — 'não sei quem' NÃO é 'o Athos faz'"}}

    # 11. ARMADO E DESPACHÁVEL
    if ARMED <= L:
        routed = (bead.get("metadata") or {}).get("gc.routed_to")
        if not routed:
            return {"state": "armed_unrouted", "turn": "mayor", "actions": ["rotear"], "reasons": {}}
        return {"state": "ready", "turn": "pool", "actions": [], "reasons": {}}

    # 12. PINNED — nota de referência permanente. Não é trabalho.
    if status == "pinned" or "pinned" in L:
        return {"state": "pinned", "turn": "nobody", "actions": [], "reasons": {}}

    # 13. HOOKED — trabalho no hook de um agente, aguardando ele pegar.
    if status == "hooked":
        crew = crew_of(assignee, known_crews)
        return {"state": "hooked", "turn": ("crew:" + crew) if crew else "pool",
                "actions": ["cutucar"] if crew else [], "reasons": {}}

    # 14. APROVADO MAS NÃO ARMADO — decisão de produto já tomada; falta armar.
    if "story:approved" in L:
        return {"state": "approved_unarmed", "turn": "mayor", "actions": ["armar"], "reasons": {}}

    # 15. BACKLOG — filado, ainda não aprovado nem armado. Vez de quem refina/prioriza.
    if status == "open":
        return {"state": "backlog", "turn": "mayor", "actions": ["refinar", "priorizar"], "reasons": {}}

    # 16. DESCONHECIDO — default é o Mayor, jamais o Athos.
    return {"state": "unknown", "turn": "mayor", "actions": ["triar"],
            "reasons": {"_diagnostico": "estado não classificável pelo modelo canônico"}}
