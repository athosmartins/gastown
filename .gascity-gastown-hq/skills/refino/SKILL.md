---
name: refino
description: >
  Facilitador interativo de refinamento de histórias de usuário. Conduz o
  agente pelos 8 campos obrigatórios um a um, reflete cada resposta de volta
  para confirmação, exige aprovação explícita antes de gravar, e escreve um
  bead de história com labels e metadados story.* corretos.
triggers:
  - "vamos refinar a história"
  - "refinar história"
  - "refinamento de história"
---

# Refino — Refinamento de Histórias de Usuário

Este skill conduz o refinamento de uma história de usuário de forma interativa,
campo a campo, com reflect-back e gate de aprovação explícita antes de gravar.

## Uso

```
/refino
```

Ou ao receber a frase: **"vamos refinar a história"**

---

## Protocolo de Condução

> **REGRA FUNDAMENTAL**: Nunca avance para o próximo campo sem refletir a
> resposta atual de volta e confirmar. Uma resposta vaga NÃO é aprovação.
> Aprovação explícita significa o usuário dizer "sim", "ok", "aprovado",
> "correto" ou equivalente inequívoco.

### Abertura

Diga ao usuário:

```
Vamos refinar a história passo a passo. Vou te fazer 8 perguntas,
uma de cada vez, e confirmar cada resposta antes de avançar.
No final, você aprova o resumo completo antes de qualquer coisa ser gravada.

Começando:
```

---

## Campo 1 — Título

**Pergunta:**
```
1/8 TÍTULO
Qual é o título da história? (formato: feat/fix/chore: descrição ação)
Exemplo: "feat(viewer): enviar PDF pelo conversation viewer"
```

**Reflect-back:**
```
Título: "<resposta do usuário>"
Está correto? (sim/corrigir)
```

Aguarde confirmação explícita antes de prosseguir.

---

## Campo 2 — Tipo

**Pergunta:**
```
2/8 TIPO
Qual o tipo?
  • feature — nova funcionalidade
  • bug     — correção de defeito
  • task    — tarefa técnica / refatoração / docs
  • chore   — manutenção, deps, configuração
```

**Reflect-back:**
```
Tipo: <resposta>
Está correto? (sim/corrigir)
```

---

## Campo 3 — Prioridade

**Pergunta:**
```
3/8 PRIORIDADE
Qual a prioridade?
  • P0 — Crítico / produção bloqueada
  • P1 — Alta / impacto direto no negócio
  • P2 — Média / melhoria relevante
  • P3 — Baixa / pode esperar
```

**Reflect-back:**
```
Prioridade: <P0/P1/P2/P3>
Está correto? (sim/corrigir)
```

---

## Campo 4 — Ator (Como...)

**Pergunta:**
```
4/8 ATOR
Como QUEM? Quem se beneficia desta história?
Exemplo: "agente de vendas", "usuário administrador", "sistema cron"
```

**Reflect-back:**
```
Ator: "<resposta>"
Está correto? (sim/corrigir)
```

---

## Campo 5 — O que quer (Quero...)

**Pergunta:**
```
5/8 DESEJO
O que esse ator QUER fazer?
Exemplo: "enviar documentos PDF pelo conversation viewer"
```

**Reflect-back:**
```
Desejo: "<resposta>"
Está correto? (sim/corrigir)
```

---

## Campo 6 — Benefício (Para que...)

**Pergunta:**
```
6/8 BENEFÍCIO
Para QUE? Qual o objetivo ou resultado esperado?
Exemplo: "fechar negócios sem sair do painel"
```

**Reflect-back:**
```
Benefício: "<resposta>"
Está correto? (sim/corrigir)
```

---

## Campo 7 — Critério de Aceite

**Pergunta:**
```
7/8 CRITÉRIO DE ACEITE
Como saberemos que está PRONTO? Liste 1-3 condições testáveis.
Exemplo:
  - Usuário seleciona PDF; arquivo enviado via Whapi
  - Arquivo aparece na conversa do destinatário
  - Erro retorna mensagem legível (não stack trace)
```

**Reflect-back:**
```
Critério de aceite:
<lista refletida de volta>
Está correto? (sim/corrigir)
```

---

## Campo 8 — Notas e Contexto

**Pergunta:**
```
8/8 NOTAS / CONTEXTO
Algum contexto adicional, restrições, ou referências? (pode dizer "nenhum")
```

**Reflect-back:**
```
Contexto: "<resposta ou 'sem contexto adicional'>"
Está correto? (sim/corrigir)
```

---

## Gate de Aprovação (OBRIGATÓRIO antes de gravar)

Após coletar todos os 8 campos, apresente o resumo completo:

```
═══════════════════════════════════════════
RESUMO DA HISTÓRIA — AGUARDANDO APROVAÇÃO
═══════════════════════════════════════════
Título:    <título>
Tipo:      <tipo>
Prioridade: <prioridade>

Como <ator>, quero <desejo>, para que <benefício>.

Critério de aceite:
<critérios listados>

Contexto: <notas>
═══════════════════════════════════════════

APROVADO para gravar? (responda "aprovado" ou corrija algum campo)
```

> **GATE**: Só avance se o usuário responder com aprovação EXPLÍCITA e
> INEQUÍVOCA. Respostas como "acho que sim", "pode ser", "tá bom acho"
> NÃO são aprovação — peça confirmação clara.

---

## Gravação do Bead (após aprovação)

Execute o comando `bd create` com todos os campos coletados:

```bash
bd create "<título>" \
  --type <tipo> \
  --priority <prioridade> \
  --labels "story.actor=<ator-slug>,story.want=<desejo-slug>,lifecycle=backlog" \
  --acceptance "<critério de aceite>" \
  --description "Como <ator>, quero <desejo>, para que <benefício>." \
  --metadata "{
    \"story.actor\": \"<ator>\",
    \"story.want\": \"<desejo>\",
    \"story.goal\": \"<benefício>\",
    \"story.acceptance\": \"<critério de aceite>\",
    \"story.context\": \"<notas>\"
  }"
```

**Regras de gravação:**
- `--type` usa o valor exato escolhido no Campo 2
- `--priority` usa P0/P1/P2/P3 do Campo 3
- Labels: `story.actor`, `story.want` e `lifecycle=backlog` (exatamente UMA label lifecycle)
- Slugs: converter espaços para `-`, remover acentos, lowercase
- `--metadata` recebe os campos de story.* com valores completos (não slugs)

---

## Convenção de Story Beads

Ver: `city-local/references/story-bead-convention.md`

Resumo:
- Tipo bead: `feature` (ou `bug`/`task`/`chore` conforme o caso)
- Labels: `story.actor`, `story.want`, `lifecycle` (exatamente UMA)
- Metadados: `story.actor`, `story.want`, `story.goal`, `story.acceptance`, `story.context`
- Nunca mais de uma label `lifecycle` no mesmo bead

---

## Após Gravar

Informe o ID do bead criado e exiba o comando que foi executado para auditoria.

Exemplo de saída esperada:
```
✓ Bead criado: wa-xyzw
  Título: feat(viewer): enviar PDF pelo conversation viewer
  Tipo: feature · Prioridade: P1 · lifecycle: backlog
```
