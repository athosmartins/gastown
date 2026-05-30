# dc-lsvz — Gas City: investigação e recomendação de migração

**Autor:** crew/thies · **Data:** 2026-05-30 · **Tipo:** research + recomendação (NÃO executei migração)
**Revisão adversarial:** rodada e incorporada (mudou minha conclusão — ver §6).

---

## TL;DR — Recomendação

**INICIAR UM SPIKE TIME-BOXED AGORA (1–3 dias). Decidir migrar-ou-ficar com base na evidência do spike.**

NÃO é "migrar agora às cegas" nem "esperar até GA". Gas City **já é** o sucessor declarado, **já chegou a 1.0/1.2 estável**, e é **drop-in import** de rigs+beads. O único valor desconhecido que importa pra nós é: *quantos dos nossos ~93 commits de fork colapsam em config (packs/formulas/orders/overrides) vs. precisam de rebuild real?* Um spike sobre **cópias** de beads/Dolt responde isso em horas, com risco ~zero ao data plane de produção. Decidir depois disso.

---

## 1. O que é Gas City e qual a relação com Gas Town

- **Repo canônico:** [`gastownhall/gascity`](https://github.com/gastownhall/gascity) — Go, 854★, 280 forks, criado 2026-02-22, `pushed_at` = hoje (2026-05-30, ativo agora).
- **Descrição:** "Orchestration-builder SDK for multi-agent coding workflows" — toolkit primitive-first. Extrai a infra reusável do Gas Town num kit configurável: runtime providers (tmux/subprocess/exec/ACP/Kubernetes), work routing, formulas, orders, health patrol, e config declarativa (`pack.toml` + `city.toml` + `.gc/`).
- **Relação:** Gas City é o **sucessor explícito** do Gas Town, pelo próprio autor (Steve Yegge). Beads foi unificado sob a mesma org (gastownhall → "soon gascityhall") e segue como produto standalone. Gas City **usa o mesmo MEOW stack (Beads + Dolt)** — o data plane é compartilhado.

> Yegge, *Welcome to Gas City* (24/abr/2026): *"Gas City starts off as a drop-in replacement for the original Gas Town, and can import all your rigs and beads."*

## 2. Maturidade / produção-ready

- **Releases:** v0.15.1 (17/abr) → v1.0.0 (21/abr, "first major release") → v1.1.0 (6/mai) → **v1.2.0 (29/mai, "the stable 1.2 release")**.
- **Issues (verificado via API, não o campo inflado):** **272 issues abertas** + 164 PRs abertos (o número "436" do GitHub junta os dois). **462 issues fechadas** → mais fechadas que abertas, velocidade saudável, não "churn alarmante".
- **Palavra do autor — duas fontes, a mais nova vence:**
  - *Clown Show to v1.0* (03/abr): "in alpha testing... on track for a fast GA." ← **DESATUALIZADO**
  - *Welcome to Gas City* (24/abr): *"Gas City released version v1.0.0 this week... and is **ready for use today!**"* e *"Should you switch from Gas Town to Gas City? **Yes!** Gas City aims to be better in every way."*
- **Caveat importante do autor:** *"Do you **have** to switch? Nope, we have some new maintainers onboarding onto Gas Town this week... We're going to continue maintaining the O.G. Gas Town as long as people still need it."*

➡️ Gas Town está em **maintenance mode** (não abandono). Não há deadline forçando saída — migramos quando for net-positivo.

## 3. Comparação com nosso Gas Town atual

| Eixo | Gas Town (nosso) | Gas City |
|---|---|---|
| Modelo | Roles hardcoded em Go (mayor/witness/refinery/polecat/crew/dog) | **Primitive-first**: roles são convenção de pack, não primitivo do SDK |
| Config | Espalhada por diretórios role-específicos | Declarativa: `pack.toml`/`city.toml`/`.gc/` |
| Customização | **Fork em Go** (~93 commits nossos) | **Packs/formulas/orders/overrides** — sem forkar |
| Infra ops | Mediada por agentes (deacon etc.) | **Controller-owned** (reconcile sessions, scaling, patrol, GC) |
| Data plane | Dolt 2.0.7/2.0.8 + beads (8 DBs) | **Mesmo** Dolt+beads (requer Dolt ≥ 2.0.7 — já atendemos) |
| Cost tracking / multi-model / hooks | Parte via nossos fork-commits | **Nativos** na lista de primitivos do Gas City |

**Ganhos concretos de migrar:** vários dos nossos fork-commits (cost-recording, e possivelmente guards) podem virar **config nativa** ou packs — retirando dívida de manutenção do fork em vez de adicionar. Modelo mais flexível ("build your own orchestrator"). Ecossistema e atenção do autor concentrados aqui.

**O que perderíamos / custo:** os ~93 commits de fork são patches no Go do Gas Town; **não portam linha-a-linha**. `coming-from-gastown.md` é explícito: *"This is not 'Gas Town with renamed commands'."* Guards nossos (cross-clone-block, atlas-drift, regression pre-push hooks, convoy-suppression, BEADS_NO_AUTO_IMPORT) precisam ser **re-expressos** como orders/formulas/hooks/overrides. **MAS:** o doc ships um **pack "Gas Town" que roda réplica exata** como drop-in + seção *"Common Gastown Overrides in PackV2"* — então o comportamento-base importa drop-in; só o **delta de fork** precisa de trabalho.

## 4. Custo / risco de migração

- **Data plane (o mais assustador) é o menor risco:** migração **preserva** Dolt+beads. Não migramos os 8 DBs — eles ficam; só a camada de orquestração muda. Mesmo assim: **spike toca só CÓPIAS**, nunca os DBs de produção (Dolt é frágil no nosso setup — já perdemos 5 semanas de histórico num reset).
- **Esforço real = re-expressar o delta de fork.** Hoje são ~93 commits; quanto mais esperarmos no linha-congelada, **maior o delta** (Gas Town e Gas City divergem). Custo só cresce com a espera.
- **Risco de produção:** rodamos campanhas vivas + PIX. Cutover só após rig não-crítico rodar limpo N dias, com Gas Town instalável pra rollback.

## 5. Plano faseado (SE/QUANDO migrar) — com guardrails

1. **Spike isolado (1–3d):** instalar `gc`, rodar o pack "Gas Town" (réplica) contra **CÓPIA** de rigs+beads/Dolt. Medir: quantos dos 93 commits colapsam em config vs. precisam rebuild. **Nunca** apontar pra DB de produção.
2. **Inventário do delta:** classificar cada fork-commit → (a) obviado por feature nativa, (b) vira override/order/formula, (c) rebuild real. Sai um número de esforço.
3. **Parallel-run read-only:** Gas City lê o mesmo Dolt (RO) ao lado do Gas Town num rig; comparar comportamento.
4. **Cutover de 1 rig não-crítico primeiro.** Gas Town fica como rollback. `bd backup` antes de cada fase.
5. **Cutover total** só após rig rodar limpo N dias. Nunca mexer no `.dolt/` direto.

## 6. Revisão adversarial — o que mudou

Minha conclusão inicial era **ESPERAR até late-beta/GA**. A revisão adversarial derrubou os dois pilares dela, e eu **verifiquei independentemente** antes de aceitar:

1. **"436 issues = churn alto" — ERRADO.** Real: **272 issues** (436 inclui 164 PRs); 462 fechadas. Velocidade normal. *(verificado via GitHub search API)*
2. **"Alpha / não production-ready" — DESATUALIZADO.** Eu ancorei no post de 03/abr. O post de **24/abr** ("Welcome to Gas City") reverte: "ready for use today", "should you switch? Yes". Mais v1.2.0 "stable" em 29/mai. *(post verificado por fetch direto)*

Pilar que sobrevive: fragilidade do Dolt é real → por isso o spike toca só cópias. "Sem dor aguda hoje" é verdade, mas pesa pouco dado o maintenance-mode. Net: **ESPERAR não sobrevive → SPIKE AGORA**, decidir na evidência.

---

## Fontes
- [gastownhall/gascity (repo)](https://github.com/gastownhall/gascity) · [releases](https://github.com/gastownhall/gascity/releases) · [coming-from-gastown.md](https://github.com/gastownhall/gascity/blob/main/docs/getting-started/coming-from-gastown.md)
- [Welcome to Gas City — Yegge, 24/abr/2026](https://steve-yegge.medium.com/welcome-to-gas-city-57f564bb3607)
- [Gas Town: from Clown Show to v1.0 — Yegge, 03/abr/2026](https://steve-yegge.medium.com/gas-town-from-clown-show-to-v1-0-c239d9a407ec)
- Contagens issues/PRs/commits: GitHub REST search API (2026-05-30).
